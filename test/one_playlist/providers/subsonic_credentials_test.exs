defmodule OnePlaylist.Providers.SubsonicCredentialsTest do
  @moduledoc """
  The one provider whose connection details are typed rather than negotiated,
  which makes this the one place where a typo is the expected input.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Providers.SubsonicCredentials

  defp valid(overrides \\ %{}) do
    Map.merge(
      %{
        "server_url" => "http://music.local:4533",
        "username" => "admin",
        "password" => "hunter2"
      },
      overrides
    )
  end

  defp errors(attrs) do
    {:error, changeset} = SubsonicCredentials.apply(attrs)

    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  describe "the server URL" do
    test "accepts http and https" do
      assert {:ok, _} = SubsonicCredentials.apply(valid())

      assert {:ok, _} =
               SubsonicCredentials.apply(valid(%{"server_url" => "https://music.example"}))
    end

    test "a trailing slash is removed rather than tolerated" do
      # The user copies the URL out of their browser's address bar, which adds
      # one. Every request would then be `//rest/...`, which some servers answer
      # and others do not — a failure that depends on which server you have.
      assert {:ok, credentials} =
               SubsonicCredentials.apply(valid(%{"server_url" => "http://music.local:4533/"}))

      assert credentials.server_url == "http://music.local:4533"
    end

    test "a missing scheme is rejected, and named as the problem" do
      # `URI.parse/1` reads "localhost:4533" as scheme "localhost" with no host,
      # so the naive check reports the *port* as a bad protocol.
      assert %{server_url: ["must start with http:// or https://"]} =
               errors(valid(%{"server_url" => "localhost:4533"}))

      assert %{server_url: ["must start with http:// or https://"]} =
               errors(valid(%{"server_url" => "music.example.com"}))
    end

    test "a scheme that is not http rejects rather than being attempted" do
      assert %{server_url: ["must be an http:// or https:// address"]} =
               errors(valid(%{"server_url" => "ftp://music.local"}))
    end

    test "is never guessed at" do
      # Deliberate: defaulting to http:// would silently downgrade a server the
      # user meant to reach over TLS, and a Subsonic token is a salted MD5 that
      # anyone reading the request can replay.
      refute match?(
               {:ok, %{server_url: "http://music.example.com"}},
               SubsonicCredentials.apply(valid(%{"server_url" => "music.example.com"}))
             )
    end
  end

  describe "required fields" do
    test "all three are needed" do
      assert %{server_url: [_], username: [_], password: [_]} = errors(%{})
    end

    test "a username of spaces is not a username" do
      assert %{username: [_]} = errors(valid(%{"username" => "   "}))
    end
  end

  describe "the password" do
    test "does not appear in inspect output" do
      # This struct travels through handle_event, start_async and any crash
      # report on the way. A password in a stack trace is a password in a log.
      {:ok, credentials} = SubsonicCredentials.apply(valid())

      refute inspect(credentials) =~ "hunter2"
    end
  end

  describe "default_display_name/1" do
    test "is the host, so two servers are tellable apart" do
      assert SubsonicCredentials.default_display_name("http://music.local:4533") == "music.local"

      assert SubsonicCredentials.default_display_name("https://pi.example.com") ==
               "pi.example.com"
    end
  end
end
