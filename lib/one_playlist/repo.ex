defmodule OnePlaylist.Repo do
  use Ecto.Repo,
    otp_app: :one_playlist,
    adapter: Ecto.Adapters.Postgres

  use Bond

  require Logger

  @moduledoc """
  The application's Ecto repository, and the seam that makes RLS apply to it.

  ## Why this module has more than the generated four lines

  Ecto connects as the `postgres` role, which holds `BYPASSRLS`. Every
  `auth.uid()` policy in `priv/repo/migrations` is therefore enforced against
  PostgREST — where it does real work — and **not** against anything this
  application asks. A query here that forgets `where user_id == ^user_id`
  returns every user's rows, and nothing notices.

  That is not hypothetical. `TransferLive.Show.mount/3` shipped exactly that
  bug: it fetched a transfer by id alone, so any signed-in user could read any
  transfer — playlist name, providers, status and the whole per-track report —
  from `/transfers/<uuid>`. Adding the `where` fixed it. `as_user/3` is the
  answer to the more useful question, which is what would have *caught* it.

  ## What `as_user/3` does

  Runs a function in a transaction that has stepped down from `postgres` to
  `authenticated` and declared whose request it is:

      Repo.as_user(user_id, fn ->
        Repo.all(Transfer)     # only that user's transfers, enforced by Postgres
      end)

  Inside the block the policies apply, so a missing `where` returns nothing
  rather than everything — the failure mode becomes an empty page instead of a
  data leak. It is defence in depth, not a replacement for scoping queries: the
  `where` clauses stay, and this is what catches the one that gets forgotten.

  ## What must *not* run inside it

  `authenticated` is a deliberately weak role. It has no access to the `oban`
  schema, and only `select` on `transfers` and `transfer_items` — the grants in
  the migrations say that users read their transfers while the system writes
  them. So `Transfers.create/1`, which inserts a transfer and enqueues its job in
  one transaction, cannot run here and should not: it is a privileged operation
  performed on a user's behalf, which is a different thing from a user's own
  query.

  Background work — the Oban worker, the token refresher, migrations — stays
  privileged for the same reason. There is no user to be.
  """

  # PostgREST sets this GUC from the verified JWT and `auth.uid()` reads `sub`
  # out of it. Doing the same thing means the policies cannot tell the
  # difference between a request that arrived through PostgREST and one that
  # arrived through Phoenix, which is the property worth having: one set of
  # policies, one meaning, two doors.
  @claims_setting "request.jwt.claims"

  # `auth.uid()` reads `coalesce(request.jwt.claim.sub, request.jwt.claims->>'sub')`,
  # so the *singular* legacy setting wins when both are present. Setting only the
  # plural one would leave `as_user/3` silently overridable by whatever set the
  # singular one last — which is not a hypothetical: a test in this repository
  # sets it directly, and the override made `fetch_connection/2` return
  # "not connected" for a perfectly good connection.
  #
  # So both are written, to the same value, and both are cleared on the way out.
  # A function whose job is to establish identity must not merely *contribute* to
  # it.
  @legacy_claim_setting "request.jwt.claim.sub"

  @doc """
  Runs `fun` as `user_id`, with row level security in force.

  Returns whatever `Repo.transaction/2` returns — `{:ok, result}` or
  `{:error, reason}`.

  ## The role is reset even when the body raises

  `SET LOCAL` is undone when its *transaction* ends, and under the Ecto SQL
  sandbox there is no such end: the sandbox holds one long transaction per test
  and `Repo.transaction/2` inside it opens a savepoint. Releasing a savepoint
  does not undo a `SET LOCAL` made inside it, so without the `after` below the
  connection would stay `authenticated` for the rest of the test — and the next
  query, needing privileges, would fail somewhere unrelated.

  That is a test-only mechanism producing a production-shaped bug, so it is
  handled here rather than in the test helper.
  """
  # A precondition rather than a filter: every caller is application code that
  # has already established who is signed in, so a malformed id here is a bug in
  # this repository, not a user mistake. Answering an error tuple would let it
  # travel further from where it was introduced.
  #
  # The blank check is the one that matters. `auth.uid()` casts the claim to
  # `uuid`, and `""` casts to NULL rather than raising — so a blank id would
  # produce a session where every `auth.uid() = user_id` comparison is NULL,
  # which is not true, which silently returns zero rows. A query that finds
  # nothing looks exactly like a user who owns nothing.
  @pre user_is_identified: is_binary(user_id) and user_id != ""
  @spec as_user(String.t(), (-> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: term()
  def as_user(user_id, fun, opts \\ []) when is_function(fun, 0) do
    transaction(
      fn ->
        previous = become(user_id)

        try do
          fun.()
        after
          revert(previous)
        end
      end,
      opts
    )
  end

  @doc """
  The user Postgres currently believes it is acting for, or `nil`.

  Reads `auth.uid()` itself rather than echoing back what was set, so it answers
  the question the *policies* will ask. Used by the tests that prove `as_user/3`
  works, and useful from a console when a query returns surprisingly little.
  """
  @spec current_user_id() :: String.t() | nil
  def current_user_id do
    case query!("select auth.uid()::text", []) do
      %{rows: [[user_id]]} -> user_id
      _no_rows -> nil
    end
  end

  @doc """
  The Postgres role queries are currently running as.

  `"postgres"` outside `as_user/3`, `"authenticated"` inside it. Exists so a
  test can assert the step-down actually happened — asserting on the rows a
  query returns cannot distinguish "RLS filtered them" from "there were none".
  """
  @spec current_role() :: String.t()
  def current_role do
    %{rows: [[role]]} = query!("select current_user::text", [])
    role
  end

  # `set_config/3` rather than `SET LOCAL`, because the latter takes no
  # parameters and would mean interpolating a value into SQL. The third argument
  # is `is_local`, making every setting transaction-scoped.
  #
  # Only `sub` and `role` are sent. The whole verified JWT payload would be more
  # faithful to what PostgREST does, and is deliberately not used: it carries an
  # expiring credential's contents into every query log for no gain, since the
  # policies here read nothing else. If one ever does, this is where it changes.
  #
  # Returns what was in force beforehand, so `revert/1` can put it back rather
  # than assume. That is what makes `as_user/3` re-entrant, and it is not
  # theoretical: `Providers.disconnect/2` runs as a user and calls
  # `fetch_connection/2`, which does too. Reverting to a hard-coded `postgres`
  # would have dropped the outer scope halfway through the enclosing call — the
  # delete would then have run privileged, which is precisely the protection
  # being added here, silently absent.
  defp become(user_id) do
    previous = current_scope()
    claims = Jason.encode!(%{sub: user_id, role: "authenticated"})

    _ = query!("select set_config($1, $2, true)", [@claims_setting, claims])
    _ = query!("select set_config($1, $2, true)", [@legacy_claim_setting, user_id])
    _ = query!("select set_config('role', 'authenticated', true)", [])

    previous
  end

  # Best effort, deliberately. If the body left the transaction in a failed state
  # then every statement here raises 25P02 — and worse, that exception replaces
  # whatever the body was actually failing with, so the caller is told "current
  # transaction is aborted" instead of the real reason.
  #
  # Swallowing it is correct rather than merely convenient: a failed transaction
  # is about to roll back, and rollback discards `SET LOCAL` anyway. There is
  # nothing left to restore.
  defp revert({role, claims, sub}) do
    _ = query!("select set_config('role', $1, true)", [role])
    _ = query!("select set_config($1, $2, true)", [@claims_setting, claims || ""])
    _ = query!("select set_config($1, $2, true)", [@legacy_claim_setting, sub || ""])
    :ok
  rescue
    error in Postgrex.Error ->
      unless aborted_transaction?(error) do
        Logger.error("could not restore database privileges: #{Exception.message(error)}")
      end

      :ok
  end

  defp aborted_transaction?(%Postgrex.Error{postgres: %{code: code}}),
    do: code == :in_failed_sql_transaction

  defp aborted_transaction?(_error), do: false

  # One round trip for all three, since `become/1` needs them together.
  # `current_setting(name, true)` answers `nil` for an unset name instead of
  # raising.
  defp current_scope do
    %{rows: [[role, claims, sub]]} =
      query!(
        "select current_user::text, current_setting($1, true), current_setting($2, true)",
        [@claims_setting, @legacy_claim_setting]
      )

    {role, claims, sub}
  end
end
