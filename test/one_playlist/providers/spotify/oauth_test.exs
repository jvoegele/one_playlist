defmodule OnePlaylist.Providers.Spotify.OAuthTest do
  @moduledoc """
  Spotify's Authorization Code flow, as a confidential client.

  The security-relevant parts of an OAuth flow are the ones invisible in the
  happy path: a URL missing its `state` completes the round trip perfectly while
  accepting anybody's authorization code, and a token exchange that discards a
  rotated refresh token works until the next expiry and then fails somewhere
  else entirely. Both are tested here rather than left to the contracts alone.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Providers.Spotify.OAuth
  alias OnePlaylist.Providers.Tokens

  setup :set_req_test_from_context

  defp stub_token(body, status \\ 200) do
    Req.Test.stub(OnePlaylist.Providers.Spotify, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp token_body(overrides \\ %{}) do
    Map.merge(
      %{
        "access_token" => "at-fresh",
        "refresh_token" => "rt-fresh",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "scope" => "playlist-read-private playlist-modify-private"
      },
      overrides
    )
  end

  describe "authorization_url/1" do
    test "carries everything Spotify needs" do
      assert {:ok, %{url: url, state: state}} = OAuth.authorization_url()

      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["response_type"] == "code"
      assert query["client_id"] == "test-client-id"
      assert query["redirect_uri"] == "http://127.0.0.1:4002/auth/spotify/callback"
      assert query["state"] == state
      assert query["scope"] =~ "playlist-modify-private"
    end

    # `user-read-private` is what puts `country` on `GET /me`, and `country`
    # becomes the `market` on every read. Without it Spotify omits the field
    # rather than refusing, so catalogue visibility degrades with nothing to say
    # so — which is why the scope is requested even though nothing displays it.
    test "asks for the scope that yields a market" do
      assert {:ok, %{url: url}} = OAuth.authorization_url()

      assert url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope") =~
               "user-read-private"
    end

    # There is no PKCE verifier in this flow, so `state` is the *entire* CSRF
    # defence — see the moduledoc on `OnePlaylist.Providers.Spotify.OAuth`.
    test "the state is long enough not to be guessed" do
      assert {:ok, %{state: state}} = OAuth.authorization_url()

      assert String.length(state) >= 32
    end

    test "a fresh state every time" do
      assert {:ok, %{state: first}} = OAuth.authorization_url()
      assert {:ok, %{state: second}} = OAuth.authorization_url()

      refute first == second
    end

    test "scopes can be overridden" do
      assert {:ok, %{url: url}} = OAuth.authorization_url(scopes: ~w(playlist-read-private))

      assert url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("scope") ==
               "playlist-read-private"
    end
  end

  describe "exchange_code/1" do
    test "answers usable tokens" do
      stub_token(token_body())

      assert {:ok, %Tokens{} = tokens} = OAuth.exchange_code("the-code")

      assert tokens.access_token == "at-fresh"
      assert tokens.refresh_token == "rt-fresh"
      assert Tokens.fresh?(tokens)
      assert "playlist-modify-private" in tokens.scopes
    end

    # `redirect_uri` is sent again even though Spotify already has it from the
    # authorize leg. That is the spec, and Spotify enforces it — the exchange
    # fails with `invalid_grant` naming neither side when they disagree.
    test "sends the redirect uri back" do
      Req.Test.stub(OnePlaylist.Providers.Spotify, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "authorization_code"
        assert params["redirect_uri"] == "http://127.0.0.1:4002/auth/spotify/callback"

        Req.Test.json(conn, token_body())
      end)

      assert {:ok, %Tokens{}} = OAuth.exchange_code("the-code")
    end

    # Basic rather than the credentials in the form body. Both are legal per
    # RFC 6749 and Spotify accepts either; Basic keeps the secret out of
    # anything that logs a request body.
    test "authenticates with the client secret over Basic" do
      Req.Test.stub(OnePlaylist.Providers.Spotify, fn conn ->
        assert ["Basic " <> encoded] = Plug.Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded) == "test-client-id:test-client-secret"

        Req.Test.json(conn, token_body())
      end)

      assert {:ok, %Tokens{}} = OAuth.exchange_code("the-code")
    end

    test "a dead grant is an error rather than a retry" do
      stub_token(%{"error" => "invalid_grant", "error_description" => "Invalid code"}, 400)

      assert {:error, error} = OAuth.exchange_code("stale")
      assert Errata.reason(error) == :invalid_grant
    end
  end

  describe "refresh/1" do
    test "answers a fresh access token" do
      stub_token(token_body(%{"access_token" => "at-renewed"}))

      assert {:ok, tokens} = OAuth.refresh("rt-old")
      assert tokens.access_token == "at-renewed"
      assert Tokens.fresh?(tokens)
    end

    # The usual shape: Spotify omits `refresh_token` on a refresh. `nil` here
    # rather than absent, and `OnePlaylist.Providers.refresh/1` is what keeps
    # the stored value — losing it silently would end the connection at the
    # *next* expiry, somewhere else entirely.
    test "a response with no refresh token says nil rather than blank" do
      stub_token(token_body() |> Map.delete("refresh_token"))

      assert {:ok, tokens} = OAuth.refresh("rt-old")
      assert is_nil(tokens.refresh_token)
    end

    # The dangerous shape, and the reason the field is read at all. Spotify may
    # rotate the refresh token; a client that ignored the new one would keep
    # presenting a token the service has already retired.
    test "a rotated refresh token is carried through" do
      stub_token(token_body(%{"refresh_token" => "rt-rotated"}))

      assert {:ok, tokens} = OAuth.refresh("rt-old")
      assert tokens.refresh_token == "rt-rotated"
    end

    # Falsifiable by input rather than by mutation, and the input is a
    # misbehaving provider rather than a bug here. A token that arrives already
    # expired is worse than a failed refresh: it gets stored, it looks healthy,
    # and it fails at the next call with an error pointing somewhere else. The
    # `fresh` postcondition is what stops it being written down.
    test "an already-expired token is refused rather than stored" do
      stub_token(token_body(%{"expires_in" => 0}))

      assert_postcondition_violation(OAuth.refresh("rt-old"), label: :fresh)
    end

    test "a revoked token is an error rather than a retry" do
      stub_token(
        %{"error" => "invalid_grant", "error_description" => "Refresh token revoked"},
        400
      )

      assert {:error, error} = OAuth.refresh("rt-revoked")
      assert Errata.reason(error) == :invalid_grant
    end
  end
end
