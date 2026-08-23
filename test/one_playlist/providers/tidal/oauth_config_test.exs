defmodule OnePlaylist.Providers.Tidal.OAuthConfigTest do
  @moduledoc """
  `OAuth.config/0`'s missing-credentials path — alone in its own file, and
  `async: false`, because it is the one TIDAL test that mutates global state.

  ## Why this is not in `oauth_test.exs`

  It was, and it made the whole suite flaky: about one run in seven failed, in a
  *different* test each time, always one that had nothing to do with
  configuration.

      1) test inherited contracts a normal refresh satisfies both postconditions
         code:  assert {:ok, tokens} = Tidal.refresh_tokens("rt-valid")
         right: {:error, %OnePlaylist.Providers.Tidal.NotConfigured{...}}

  `Application.put_env/3` is process-global. Nulling out `client_id` to prove
  that `config/0` reports it does exactly what it says — for *every* concurrently
  running test, not just this one. `on_exit` restores it, but the window between
  the two is wide enough for another async file to look up the config and find
  no credentials.

  ExUnit runs `async: false` tests **after** every async one has finished, so
  moving it here is what makes the mutation safe: nothing else is running to see
  it. The rest of `oauth_test.exs` stays async.

  The general rule this is an instance of: a test that writes application
  environment, or any other global, cannot be `async: true` — and the cost of
  getting it wrong is paid by unrelated tests, which is what makes it so hard to
  diagnose from the failure.
  """

  use ExUnit.Case, async: false
  use Errata

  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.NotConfigured
  alias OnePlaylist.Providers.Tidal.OAuth

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
