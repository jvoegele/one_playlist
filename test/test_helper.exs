ExUnit.start()

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
if Application.get_env(:bond, :coverage) do
  :ets.new(:bond_coverage, [:named_table, :public, :set, {:write_concurrency, true}])
end

Bond.Coverage.install_reporter()

Ecto.Adapters.SQL.Sandbox.mode(OnePlaylist.Repo, :manual)
