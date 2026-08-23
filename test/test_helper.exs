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
# WORKAROUND (bond 1.14.1, see docs/library-feedback.md): Bond creates its
# coverage ETS table lazily, inside whichever process first evaluates a
# contract. In a suite that is a *test* process, so the table — and every
# recorded evaluation — is destroyed when that test finishes, and the
# end-of-suite report always reads "no contracts were evaluated".
#
# Creating the table here first makes it owned by the test_helper process, which
# lives for the whole run; Bond's own `ensure_table/0` then finds it and reuses
# it. Delete this once Bond creates the table from `install_reporter/0`.
# Guarded rather than unconditional. Observed once, 2026-08-23: `:ets.new/2` here
# died with "table name already exists", taking the whole run down before a
# single test started. The cause was not reproduced — the table is *not* present
# after a normal application start, checked directly — so this does not claim to
# know which process won the race, only that losing it must not be fatal.
#
# Creating a table that already exists is not something worth crashing over in
# any case: the goal is that the table exists and outlives the run, and both
# branches satisfy it.
if Application.get_env(:bond, :coverage) and :ets.whereis(:bond_coverage) == :undefined do
  :ets.new(:bond_coverage, [:named_table, :public, :set, {:write_concurrency, true}])
end

Bond.Coverage.install_reporter()

Ecto.Adapters.SQL.Sandbox.mode(OnePlaylist.Repo, :manual)
