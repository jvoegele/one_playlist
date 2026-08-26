defmodule OnePlaylist.Providers.Spotify.OAuthConfigTest do
  @moduledoc """
  `OAuth.config/0`'s missing-credentials path — alone in its own file, and
  `async: false`, because it is the one Spotify test that mutates global state.

  The reasoning is `OnePlaylist.Providers.Tidal.OAuthConfigTest`'s in full, and
  it is worth reading there: `Application.put_env/3` is process-global, so
  nulling a credential to prove `config/0` notices does it for *every*
  concurrently running test, and the failures land in unrelated files about one
  run in seven.

  This file was written into `oauth_test.exs` first, exactly as the TIDAL one
  was, and moved here for exactly the same reason — which is the argument for
  the rule rather than against it. `CLAUDE.md` states it plainly: a test that
  writes application environment cannot be `async: true`.

  ## What is different from TIDAL's

  Spotify is a **confidential** client, so it needs two values where TIDAL needs
  one, and the second is the one a setup actually forgets. Both absences are
  tested, and each names its own variable — a message saying only "Spotify is
  not configured" sends a reader to look at all of it.
  """

  use ExUnit.Case, async: false
  use Errata

  alias OnePlaylist.Providers.Spotify
  alias OnePlaylist.Providers.Spotify.NotConfigured
  alias OnePlaylist.Providers.Spotify.OAuth

  setup do
    original = Application.get_env(:one_playlist, Spotify)
    on_exit(fn -> Application.put_env(:one_playlist, Spotify, original) end)

    %{original: original}
  end

  defp without(original, key) do
    Application.put_env(:one_playlist, Spotify, Keyword.put(original, key, nil))
  end

  describe "config/0" do
    test "reports missing credentials as a configuration error", %{original: original} do
      without(original, :client_id)

      assert {:error, %NotConfigured{} = error} = OAuth.authorization_url()
      assert Errata.http_status(error) == 501
      refute Errata.retryable?(error)
    end

    test "names the client id when that is what is absent", %{original: original} do
      without(original, :client_id)

      assert {:error, error} = OAuth.config()
      assert Errata.display_message(error) =~ "SPOTIFY_CLIENT_ID"
    end

    # The one a real setup actually hits. A `dev_local.exs` copied before Spotify
    # existed carries no Spotify block at all, and TIDAL's secret being optional
    # makes "the secret is required" easy to skim past.
    test "names the client secret when that is what is absent", %{original: original} do
      without(original, :client_secret)

      assert {:error, error} = OAuth.config()
      assert Errata.display_message(error) =~ "SPOTIFY_CLIENT_SECRET"
      refute Errata.display_message(error) =~ "SPOTIFY_CLIENT_ID"
    end
  end
end
