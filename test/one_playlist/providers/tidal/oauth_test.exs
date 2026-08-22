defmodule OnePlaylist.Providers.Tidal.OAuthTest do
  use ExUnit.Case, async: true

  use Errata

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.NotConfigured
  alias OnePlaylist.Providers.Tidal.OAuth
  alias OnePlaylist.Providers.TokenRefreshFailed

  # Several test files stub Req under this same name and all run async. Without
  # per-test ownership they overwrite one another, and a test intermittently
  # gets a response meant for a different one. Same idea as the Ecto sandbox:
  # private ownership for async tests, shared for sync ones.
  setup :set_req_test_from_context

  describe "authorization_url/1" do
    test "builds a PKCE authorization URL" do
      assert {:ok, %{url: url, code_verifier: verifier, state: state}} =
               OAuth.authorization_url()

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://login.tidal.com/authorize"
      assert query["response_type"] == "code"
      assert query["client_id"] == "test-client-id"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == state

      # The challenge must be the S256 hash of the verifier, not the verifier
      # itself — sending the verifier would make PKCE decorative.
      expected = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
      assert query["code_challenge"] == expected
      refute query["code_challenge"] == verifier
    end

    test "requests the scopes a transfer tool actually needs" do
      {:ok, %{url: url}} = OAuth.authorization_url()
      scopes = url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope")

      assert scopes =~ "playlists.write"
      assert scopes =~ "playlists.read"
      assert scopes =~ "collection.write"
    end

    test "verifier and state are fresh on every call" do
      {:ok, first} = OAuth.authorization_url()
      {:ok, second} = OAuth.authorization_url()

      refute first.code_verifier == second.code_verifier
      refute first.state == second.state
    end
  end

  describe "exchange_code/2" do
    test "returns tokens on success" do
      Req.Test.stub(Tidal, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/oauth2/token"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "authorization_code"
        assert params["code"] == "the-code"
        assert params["code_verifier"] == "the-verifier"

        Req.Test.json(conn, %{
          "access_token" => "at-1",
          "refresh_token" => "rt-1",
          "expires_in" => 3600,
          "scope" => "playlists.read playlists.write"
        })
      end)

      assert {:ok, tokens} = OAuth.exchange_code("the-code", "the-verifier")
      assert tokens.access_token == "at-1"
      assert tokens.refresh_token == "rt-1"
      assert tokens.scopes == ["playlists.read", "playlists.write"]
      assert DateTime.after?(tokens.expires_at, DateTime.utc_now())
    end

    test "sends the client secret, since a server is a confidential client" do
      Req.Test.stub(Tidal, fn conn ->
        assert ["Basic " <> encoded] = Plug.Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded) == "test-client-id:test-client-secret"

        Req.Test.json(conn, %{"access_token" => "at", "expires_in" => 3600})
      end)

      assert {:ok, _tokens} = OAuth.exchange_code("c", "v")
    end
  end

  describe "refresh/1" do
    test "returns a new access token" do
      Req.Test.stub(Tidal, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "rt-old"

        Req.Test.json(conn, %{"access_token" => "at-new", "expires_in" => 3600})
      end)

      assert {:ok, tokens} = OAuth.refresh("rt-old")
      assert tokens.access_token == "at-new"

      assert tokens.refresh_token == nil,
             "TIDAL need not return a new refresh token; the caller keeps the old one"
    end

    test "a dead grant is reported as non-retryable and is not retried" do
      # The shape here is the one the live endpoint actually returns.
      Req.Test.stub(Tidal, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "invalid_grant",
          "error_description" => "Token has invalid payload",
          "status" => 400,
          "sub_status" => 1005
        })
      end)

      assert {:error, %TokenRefreshFailed{} = error} = OAuth.refresh("rt-dead")
      assert Errata.reason(error) == :invalid_grant

      refute Errata.retryable?(error),
             "retrying a dead grant is how an integration wedges itself"
    end

    test "a 5xx is retried and then reported as retryable" do
      counter = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 503, "upstream unavailable")
      end)

      assert {:error, error} = OAuth.refresh("rt-1")

      # max_attempts is 3 in the test environment, so a persistently failing
      # call should have actually been attempted three times.
      assert :counters.get(counter, 1) == 3, "the retry path did not run"

      assert %ExternalService.RetriesExhausted{} = error
      assert %TokenRefreshFailed{} = Errata.cause(error)
      assert Errata.retryable?(Errata.cause(error))
    end
  end

  describe "config/0" do
    test "reports missing credentials as a configuration error" do
      original = Application.get_env(:one_playlist, Tidal)
      on_exit(fn -> Application.put_env(:one_playlist, Tidal, original) end)

      Application.put_env(:one_playlist, Tidal, Keyword.put(original, :client_id, nil))

      assert {:error, %NotConfigured{} = error} = OAuth.authorization_url()
      assert Errata.http_status(error) == 501
      refute Errata.retryable?(error)
    end
  end
end
