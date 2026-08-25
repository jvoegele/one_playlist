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

# The same question about the other library: which services did the suite ever
# take down a failure path? A guarded call that only ever succeeds exercises
# none of the four mechanisms, and a suite full of them looks identical to one
# that tests every one.
#
# A row of zeros is a prompt rather than a verdict — a provider stubbed at our
# own boundary is *supposed* to have them. It is the service we believed we were
# testing that the report is for. Never a threshold, never a build failure.
#
# Installed here for the same reason as Bond's, and the library warns about it
# in the same words: the counts live in an ETS table, and an ETS table dies with
# the process that created it. This process outlives the suite; a test does not.
ExternalService.Test.Coverage.install_reporter()

Ecto.Adapters.SQL.Sandbox.mode(OnePlaylist.Repo, :manual)
