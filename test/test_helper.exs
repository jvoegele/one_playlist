# `:supabase` tests talk to a real GoTrue rather than a stub, because the SDK
# chooses its HTTP client inside the request and `Req.Test` cannot reach it.
# Excluded by default so the suite stays hermetic and fast; see
# `test/one_playlist/accounts_test.exs` for the command that runs them.
ExUnit.start(exclude: [:supabase])

# Reports which Bond assertions ran and which were ever seen to fail. An
# assertion that is checked many times and never fails is a candidate for the
# vacuous contract Bond's guides warn about — it looks like coverage while
# asserting nothing. Enabled by `config :bond, coverage: true` in config/test.exs.
#
# No `:ets.new/2` preamble is needed: as of bond 1.15.0 `install_reporter/0`
# creates the coverage table itself, so it is owned by this process rather than
# by whichever test first evaluated a contract, and does not die with it. See
# docs/library-feedback.md.
Bond.Coverage.install_reporter()

Ecto.Adapters.SQL.Sandbox.mode(OnePlaylist.Repo, :manual)
