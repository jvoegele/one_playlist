defmodule OnePlaylist.Providers do
  @moduledoc """
  Users' authorizations to act on their behalf at music services.

  This context owns the OAuth token lifecycle, which is the highest-risk part of
  the application: Supabase Auth hands us a `provider_token` and
  `provider_refresh_token` exactly once, at sign-in, and then neither stores nor
  refreshes them. Everything downstream — transfers, scheduled sync — assumes a
  working token is available unattended, and that assumption is this module's
  responsibility. See `docs/reference/supabase.md`.

  Tokens are encrypted by `OnePlaylist.Vault` before they reach Postgres, so
  they are ciphertext at rest and in backups.

  ## Scope

  Every read is scoped to a `user_id`. There is deliberately no
  `get_connection(id)` that ignores who is asking — the one shape this module
  exposes makes the scoping impossible to forget. The rows are also protected by
  RLS, but the application connects as the table owner, so RLS is defence in
  depth here rather than the primary control.
  """

  import Ecto.Query

  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionNotFound
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.ProviderNotSupported
  alias OnePlaylist.Providers.SubsonicCredentials
  alias OnePlaylist.Repo

  use Bond
  use Errata

  @type user_id :: Ecto.UUID.t()

  @doc """
  Lists a user's connections, most recently connected first.

  Runs under `OnePlaylist.Repo.as_user/3`, so the `where` below is not the only
  thing standing between one user and another's credentials — Postgres applies
  the `own connections select` policy to the same query. Belt and braces, on the
  path that reads encrypted access tokens.
  """
  @spec list_connections(user_id()) :: [Connection.t()]
  def list_connections(user_id) do
    {:ok, connections} =
      Repo.as_user(user_id, fn ->
        Connection
        |> where(user_id: ^user_id)
        |> order_by(desc: :inserted_at)
        |> Repo.all()
      end)

    connections
  end

  @doc """
  Fetches one connection.

  Returns `{:error, %ConnectionNotFound{}}` rather than `nil` so the failure
  carries the provider and user it was looking for into whatever logs it.
  """
  @spec fetch_connection(user_id(), Connection.provider()) ::
          {:ok, Connection.t()} | {:error, ConnectionNotFound.t()}
  def fetch_connection(user_id, provider) do
    # Scoped twice, for the reason `list_connections/1` gives. Safe to call from
    # the Oban runner as well as from a request: `as_user/3` is self-contained,
    # reverting the role before it returns, so the privileged work either side of
    # it is unaffected.
    {:ok, found} =
      Repo.as_user(user_id, fn ->
        Repo.get_by(Connection, user_id: user_id, provider: provider)
      end)

    case found do
      nil ->
        {:error,
         Errata.create(ConnectionNotFound,
           context: %{user_id: user_id, provider: provider}
         )}

      connection ->
        {:ok, connection}
    end
  end

  @doc """
  Fetches a connection that is ready to call the provider with.

  This is the function callers should reach for. It distinguishes the three
  situations that a bare fetch conflates: no connection at all, a connection
  that needs the user to reconnect, and a usable one.

  It **does** refresh an access token at or near expiry, via `ensure_fresh/2`.

  That reverses an earlier decision, which was that refreshing needs an HTTP
  call and therefore belonged in the adapter. The layering was tidier and the
  refresh never happened: `ensure_fresh/2` is documented as "the function every
  provider call should go through" and had **no callers at all**. A TIDAL
  connection stopped working an hour after it was made, every call answering
  `unauthorized`, until somebody reconnected by hand — which is what
  `docs/reference/domain.md` calls the highest-risk component failing silently.

  The HTTP call still goes through `ExternalService`, because `refresh/1`
  reaches the provider through `adapter.refresh_tokens/1`. What changed is only
  *who asks*, and this is where everything already comes.

  Cheap in the common case: a token with more than the skew left is returned
  untouched, with no request.
  """
  @spec fetch_usable_connection(user_id(), Connection.provider()) ::
          {:ok, Connection.t()}
          | {:error, ConnectionNotFound.t() | ConnectionUnusable.t()}
  def fetch_usable_connection(user_id, provider) do
    with {:ok, connection} <- fetch_connection(user_id, provider) do
      if Connection.usable?(connection) do
        # `usable?/1` asks whether there are credentials at all; it says nothing
        # about whether they still work. A connection can be active, hold a
        # token, and have been expired for an hour.
        ensure_fresh(connection)
      else
        {:error,
         Errata.create(ConnectionUnusable,
           reason: unusable_reason(connection),
           context: %{user_id: user_id, provider: provider}
         )}
      end
    end
  end

  defp unusable_reason(%Connection{status: :active}), do: :reauth_required
  defp unusable_reason(%Connection{status: status}), do: status

  @doc """
  Records the result of an OAuth authorization.

  Upserts on `(user_id, provider)`: reconnecting an already-connected service
  replaces the tokens rather than failing or creating a second row. A successful
  connect always clears `status`, `last_error` and `consecutive_failures` — the
  user has just proved the authorization works, so any earlier failure is stale.
  """
  # An upsert whose `:replace` list drifts out of step with the schema is the
  # bug these guard: a reconnect that silently keeps a stale value. These cannot
  # catch a *missing* field (see the round-trip test in providers_test.exs), but
  # they do catch the identity and lifecycle fields going wrong, which is where
  # a mistake would be least visible.
  @post whenever(
          {:ok, connection} <- result,
          belongs_to_requester: connection.user_id == user_id,
          stored_under_requested_provider: connection.provider == provider,
          connect_clears_prior_failure:
            connection.status == :active and connection.consecutive_failures == 0
        )
  @spec connect(user_id(), Connection.provider(), map()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def connect(user_id, provider, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{
        "user_id" => user_id,
        "provider" => provider,
        "status" => :active,
        "last_error" => nil,
        "consecutive_failures" => 0
      })

    # Under `Repo.as_user/3`, so the row Postgres stores is checked against
    # `own connections insert`'s WITH CHECK as well as being built with the right
    # `user_id` here. An upsert needs both policies: the insert's WITH CHECK for
    # the attempted row, and the update's USING and WITH CHECK for the conflict
    # path — `authenticated` holds all of them, plus the SELECT that
    # `returning: true` and conflict detection require.
    {:ok, result} =
      Repo.as_user(user_id, fn ->
        upsert_connection(attrs)
      end)

    result
  end

  defp upsert_connection(attrs) do
    %Connection{}
    |> Connection.changeset(attrs)
    |> Repo.insert(
      # Encryption keeps tokens out of the *database* as plaintext. It does
      # nothing for the query log, which prints every bound parameter — and the
      # parameters here are the tokens, pre-encryption. Observed leaking both a
      # live access and refresh token into the dev log at :debug.
      #
      # `log: false` is the blunt fix, and the right one: no log line is worth a
      # credential that grants standing access to someone's music library. It
      # costs the timing entry for this one query.
      log: false,
      # A constraint violation — a `user_id` naming no row in `auth.users` is the
      # realistic one — aborts the enclosing transaction in Postgres, and every
      # statement after it fails with 25P02 until rollback. Inside
      # `Repo.as_user/3` that enclosing transaction is real, so without a
      # savepoint the failure destroys the changeset error on its way out and
      # reports "current transaction is aborted" instead of "that user does not
      # exist".
      mode: :savepoint,
      # Without `returning: true` an upsert hands back the id Ecto generated
      # client-side rather than the id of the row that actually exists, so a
      # reconnect would return a struct whose primary key matches nothing.
      returning: true,
      on_conflict:
        {:replace,
         [
           :provider_user_id,
           :display_name,
           :country,
           :access_token,
           :refresh_token,
           :access_token_expires_at,
           :scopes,
           :status,
           :last_error,
           :consecutive_failures,
           :updated_at
         ]},
      conflict_target: [:user_id, :provider]
    )
  end

  @doc """
  Connects a Subsonic-compatible server, **after proving the credential works**.

  ## Why this is not just `connect/3`

  Every other provider arrives here having already proved itself: an OAuth code
  was exchanged for a token, so a stored TIDAL connection is known to work at
  the moment it is stored. A Subsonic credential is typed in, and a typo is
  indistinguishable from a correct password until somebody calls the server.

  Storing it unverified would push that failure to the *next* thing the user
  does — a transfer, minutes or days later, which fails with "unauthorized" and
  no obvious connection to the form they filled in. So this calls `whoami/1`
  with an unsaved connection first, and persists only on success. The cost is
  one round trip on a screen where the user is already waiting.

  `whoami/1` rather than `ping`: a Subsonic server answers `ping` with `ok`
  even when it is not checking credentials at all.

  ## Stored as `:navidrome`

  `Connection` knows a `:subsonic` provider too, but only one adapter exists and
  it is registered under `:navidrome`. Since Navidrome, Airsonic, Gonic and
  Subsonic itself all speak the same API, a second registration would be the
  same module under a second name — and `Adapter.provider/0` can only answer
  one of them, which the adapter's own contract checks. One name until a server
  turns up that genuinely needs different handling.
  """
  @spec connect_subsonic(user_id(), SubsonicCredentials.t()) ::
          {:ok, Connection.t()} | {:error, Errata.error() | Ecto.Changeset.t()}
  def connect_subsonic(user_id, %SubsonicCredentials{} = credentials) do
    provider = :navidrome

    # Never persisted. It exists only so `whoami/1` — which takes a connection,
    # because a Subsonic call needs the server's address as well as the
    # credential — can be asked the question before the row exists.
    candidate = %Connection{
      user_id: user_id,
      provider: provider,
      provider_user_id: credentials.username,
      server_url: credentials.server_url,
      access_token: credentials.password,
      status: :active
    }

    with {:ok, adapter} <- adapter(provider),
         {:ok, _account} <- adapter.whoami(candidate) do
      connect(user_id, provider, %{
        provider_user_id: credentials.username,
        display_name:
          credentials.display_name ||
            SubsonicCredentials.default_display_name(credentials.server_url),
        server_url: credentials.server_url,
        access_token: credentials.password,
        # Both nil, and both load-bearing. `Connection.needs_refresh?/3` answers
        # `false` for a nil expiry, which is the whole reason a never-expiring
        # credential needs no special case anywhere else. Setting an expiry here
        # would send `ensure_fresh/2` to `Navidrome.refresh_tokens/1`, which
        # returns `:reauth_required` — marking a working connection dead. See
        # the round-trip test in providers_test.exs.
        refresh_token: nil,
        access_token_expires_at: nil
      })
    end
  end

  @doc """
  Replaces the tokens on a connection after a successful refresh.

  Clears the failure counters for the same reason `connect/3` does.
  """
  # `connections_due_for_refresh/2` only considers `:active` connections, so a
  # success that failed to clear the failure state would quietly remove this
  # connection from the refresh schedule forever — it would keep working until
  # the token expired, then die, with nothing in the logs to say why.
  @post whenever(
          {:ok, refreshed} <- result,
          refresh_clears_failure_state:
            refreshed.status == :active and refreshed.consecutive_failures == 0,
          refresh_is_recorded: is_struct(refreshed.last_refreshed_at, DateTime)
        )
  @spec record_refresh(Connection.t(), map()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def record_refresh(%Connection{} = connection, attrs) do
    # Runs as the connection's owner even though the caller is usually the
    # background refresher rather than a request. There is no reason for a
    # system job to hold more privilege than the row it is touching needs, and
    # the owner is right there on the struct — so the `own connections update`
    # policy applies here too, and a refresher that somehow addressed the wrong
    # row would update nothing instead.
    {:ok, result} =
      Repo.as_user(connection.user_id, fn ->
        connection
        |> Connection.changeset(
          Map.merge(Map.new(attrs), %{
            last_refreshed_at: DateTime.utc_now(),
            status: :active,
            last_error: nil,
            consecutive_failures: 0
          })
        )
        # Carries tokens as query parameters — see the note in `connect/3`.
        |> Repo.update(log: false, mode: :savepoint)
      end)

    result
  end

  @doc """
  Records a failed refresh.

  `status` is only moved off `:active` when the provider told us the grant is
  dead. A transient failure leaves the connection active and merely increments
  the counter, so a provider outage does not mass-disconnect every user — which
  would turn a ten-minute upstream blip into a re-authorization campaign.
  """
  # The counter is how "this connection keeps failing" will eventually be
  # noticed. A rewrite that assigned rather than incremented — `1` for
  # `connection.consecutive_failures + 1` — would peg it at one forever and no
  # threshold would ever trigger. Nothing would fail; the signal would just
  # never arrive.
  @post whenever(
          {:ok, failed} <- result,
          counter_advances_by_one:
            failed.consecutive_failures == connection.consecutive_failures + 1,
          failure_never_reactivates: failed.status != :active or connection.status == :active
        )
  @spec record_failure(Connection.t(), Exception.t()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(%Connection{} = connection, error) do
    status = if requires_reauth?(error), do: :reauth_required, else: connection.status

    # As the owner, for the reason `record_refresh/2` gives.
    {:ok, result} =
      Repo.as_user(connection.user_id, fn ->
        connection
        |> Connection.changeset(%{
          status: status,
          last_error: Exception.message(error),
          consecutive_failures: connection.consecutive_failures + 1
        })
        |> Repo.update(mode: :savepoint)
      end)

    result
  end

  # Whether a failure means the *user* must act, as opposed to us trying again
  # later.
  #
  # The question has to be asked of the underlying failure, not the error in
  # hand. A guarded call that exhausts its retries returns
  # `ExternalService.RetriesExhausted`, which is itself deliberately *not*
  # retryable — "retrying is precisely what has already been tried". Asking it
  # directly would read a TIDAL outage as a dead grant and demand that every
  # affected user reconnect, which is the exact failure this function exists to
  # prevent.
  #
  # `RetriesExhausted` carries the real failure as its `:cause`, so unwrap to it
  # first. Anything that is not an Errata error is treated as transient: an
  # unrecognised failure is a poor reason to disconnect somebody.
  defp requires_reauth?(error) do
    underlying = root_cause(error)
    Errata.is_error(underlying) and not Errata.retryable?(underlying)
  end

  @doc """
  Unwraps a guarded call's failure to the error that actually caused it.

  `ExternalService` wraps whatever went wrong in a `RetriesExhausted`, whose own
  message says only that retrying did not help. That is the right thing to
  *classify* on — see `requires_reauth?/1` — and the wrong thing to *show*: a
  user whose music server is switched off should be told the connection was
  refused, not that this application gave up retrying.

  Errors that are not Errata errors, and Errata errors with no cause, are
  returned as they are.
  """
  @spec root_cause(term()) :: term()
  def root_cause(error) do
    if Errata.is_error(error) do
      case Errata.cause(error) do
        nil -> error
        cause -> root_cause(cause)
      end
    else
      error
    end
  end

  @doc """
  Connections whose access token expires within `skew_seconds`.

  This is the refresh scheduler's query. Only `:active` connections are
  considered — one already needing re-authorization cannot be fixed by us.
  """
  # This query and `Connection.needs_refresh?/3` are the same rule written twice,
  # once in SQL and once in Elixir. Nothing but this postcondition keeps them in
  # step, and drift is silent in both directions: too wide and the scheduler
  # burns provider quota refreshing tokens that were fine, too narrow and
  # connections quietly pass their expiry and die.
  #
  # `DateTime.utc_now/0` is read again here, marginally later than the query
  # used it, which can only make the predicate *more* likely to hold — so the
  # re-read cannot produce a false failure.
  @pre non_negative_skew: is_integer(skew_seconds) and skew_seconds >= 0
  @pre skew_under_a_day: skew_seconds <= 86_400
  @post query_agrees_with_predicate:
          forall(
            connection <- result,
            Connection.needs_refresh?(connection, DateTime.utc_now(), skew_seconds)
          )
  @spec connections_due_for_refresh(non_neg_integer(), keyword()) :: [Connection.t()]
  def connections_due_for_refresh(skew_seconds \\ 300, opts \\ []) do
    deadline = DateTime.add(DateTime.utc_now(), skew_seconds, :second)
    limit = Keyword.get(opts, :limit, 100)

    Connection
    |> where([c], c.status == :active)
    |> where([c], not is_nil(c.access_token_expires_at))
    |> where([c], c.access_token_expires_at <= ^deadline)
    |> order_by([c], asc: c.access_token_expires_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Ensures a connection has a usable access token, refreshing it if it is close
  to expiry.

  This is the function every provider call should go through. It is idempotent
  and cheap in the common case — a connection with time left is returned
  untouched, with no HTTP call.

  Failure is recorded on the connection as a side effect (see
  `record_failure/2`), so a caller that ignores the error still leaves a trail,
  and a dead grant is marked as needing re-authorization rather than being
  retried forever.
  """
  @spec ensure_fresh(Connection.t(), keyword()) ::
          {:ok, Connection.t()} | {:error, Errata.error()}
  def ensure_fresh(%Connection{} = connection, opts \\ []) do
    skew = Keyword.get(opts, :skew_seconds, 300)

    if Connection.needs_refresh?(connection, DateTime.utc_now(), skew) do
      refresh(connection)
    else
      {:ok, connection}
    end
  end

  @doc """
  Exchanges a connection's refresh token for a new access token.

  Refreshes unconditionally; `ensure_fresh/2` is the one that decides whether it
  is needed.
  """
  # The law the `|| connection.refresh_token` fallback in the body exists to
  # uphold. A provider need not return a new refresh token, and TIDAL usually
  # does not; a rewrite that trusted the response would set it to nil, and the
  # connection would work perfectly until the next expiry and then be
  # unrecoverable without the user reconnecting. Slow, silent, and affecting
  # every user at once.
  @post whenever(
          {:ok, refreshed} <- result,
          refresh_token_is_never_lost:
            not is_binary(connection.refresh_token) or is_binary(refreshed.refresh_token),
          access_token_actually_changed_or_expiry_advanced:
            is_struct(refreshed.access_token_expires_at, DateTime)
        )
  @spec refresh(Connection.t()) :: {:ok, Connection.t()} | {:error, Errata.error()}
  # `nil` **or blank**, and the blank half was missing until Meyer's
  # Non-Redundancy principle was applied to this call site (*OOSC* §11.6): a
  # client must establish the precondition of what it calls, and
  # `c:OnePlaylist.Providers.Adapter.refresh_tokens/1` requires a non-blank
  # token. Matching only `nil` left `""` to reach it and raise
  # `Bond.PreconditionError` out of `ensure_fresh/2` — so a transfer crashed
  # where it should have failed cleanly, telling the user to reconnect.
  #
  # `Tokens`' `refresh_token_absent_or_real` invariant stops a blank one being
  # *written* today, but rows persisted before it existed are still out there,
  # and a contract does not retroactively clean a database.
  def refresh(%Connection{refresh_token: token} = connection) when token in [nil, ""] do
    error =
      Errata.create(ConnectionUnusable,
        reason: :reauth_required,
        context: %{provider: connection.provider, user_id: connection.user_id}
      )

    _ = record_failure(connection, error)
    {:error, error}
  end

  def refresh(%Connection{} = connection) do
    with {:ok, adapter} <- adapter(connection.provider),
         {:ok, tokens} <- adapter.refresh_tokens(connection.refresh_token) do
      record_refresh(connection, %{
        access_token: tokens.access_token,
        # A provider need not return a new refresh token, and TIDAL usually does
        # not. Keeping the existing one is not a nicety: overwriting it with nil
        # would end the connection at the next expiry, and the user would have
        # to reconnect for no reason.
        #
        # `||` is safe here only because `%Tokens{}` cannot carry `""` — an
        # empty string is truthy and would sail through this fallback, and past
        # `refresh_token_is_never_lost` below, to leave the connection holding a
        # refresh token that fails its own precondition next time. That is the
        # `refresh_token_absent_or_real` invariant's job.
        refresh_token: tokens.refresh_token || connection.refresh_token,
        access_token_expires_at: tokens.expires_at,
        scopes: if(tokens.scopes == [], do: connection.scopes, else: tokens.scopes)
      })
    else
      {:error, error} ->
        _ = record_failure(connection, error)
        {:error, error}
    end
  end

  @adapters %{
    tidal: OnePlaylist.Providers.Tidal,
    navidrome: OnePlaylist.Providers.Navidrome
  }

  @doc """
  The `OnePlaylist.Providers.Adapter` implementation for a provider.

  A map rather than function clauses so that `supported_providers/0` can be
  derived from it — two lists that must agree is one list too many.

  Returns an error rather than raising, because `Connection` deliberately
  accepts more providers than are implemented: the schema documents the
  roadmap, and asking for one of the unbuilt ones is a `501`, not a crash.
  """
  @spec adapter(Connection.provider()) ::
          {:ok, module()} | {:error, ProviderNotSupported.t()}
  @doc """
  Whether a service can do a given thing.

  Answers `false` for a provider this application does not know, rather than
  raising: the question "can it do X" has a sensible answer for a service that
  is not there at all, and every call site is a branch that already has to
  handle "no".

      iex> alias OnePlaylist.Providers
      iex> {Providers.supports?(:tidal, :artwork), Providers.supports?(:navidrome, :artwork)}
      {true, false}
      iex> Providers.supports?(:tidal, :remove_tracks)
      false
  """
  @spec supports?(atom(), Adapter.capability()) :: boolean()
  def supports?(provider, capability) do
    case adapter(provider) do
      {:ok, module} -> capability in module.capabilities()
      {:error, _reason} -> false
    end
  end

  def adapter(provider) do
    case Map.fetch(@adapters, provider) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, Errata.create(ProviderNotSupported, context: %{provider: provider})}
    end
  end

  @doc "Providers this application can actually talk to today."
  @spec supported_providers() :: [Connection.provider()]
  def supported_providers, do: Map.keys(@adapters)

  @doc "Removes a connection, revoking this application's access locally."
  # Only the pure half of what this function guarantees is asserted here, and
  # the omission is deliberate.
  #
  # The interesting law is about *blast radius*: a rewrite to `Repo.delete_all`
  # with a filter that drops the `user_id` clause would wipe other people's
  # connections while still satisfying "the requested one is gone". Expressing
  # that needs a before-and-after count of shared state —
  # `connection_count() == old(connection_count()) - 1` — and that assertion is
  # unsound. Any concurrent `connect/3` or `disconnect/2` by a *different user*
  # can interleave between the `old/1` snapshot and the check, and the
  # postcondition then fails on code that did exactly what it was asked to.
  #
  # Bond's own `contracts-and-concurrency` guide names this the worst failure
  # mode a contract can have: it accuses correct code, and teaches you to
  # distrust the contract rather than the program. Its advice is to assert only
  # what the implementation can actually guarantee under interleaving — and for
  # a global table count under concurrent writes, that is nothing at all.
  #
  # So the blast-radius law lives in a test instead
  # (`providers_test.exs`, "disconnecting removes one row and leaves other users
  # alone"), where the sandbox makes the state genuinely exclusive and the strong
  # assertion is sound. Verified to catch the `delete_all` rewrite on its own.
  #
  # What survives here is race-free because it touches no shared state: it is a
  # claim about the struct this call returned.
  @post whenever(
          {:ok, removed} <- result,
          removed_what_was_asked_for: removed.user_id == user_id and removed.provider == provider
        )
  @spec disconnect(user_id(), Connection.provider()) ::
          {:ok, Connection.t()} | {:error, ConnectionNotFound.t()}
  def disconnect(user_id, provider) do
    # `own connections delete`'s USING clause means a row belonging to somebody
    # else is not merely refused — it is not visible to the DELETE at all, so a
    # scoping mistake removes nothing rather than the wrong thing.
    #
    # `fetch_connection/2` nests its own `as_user/3` inside this one. That works
    # because the inner scope restores the outer rather than dropping to
    # `postgres`; see `OnePlaylist.Repo`.
    {:ok, result} =
      Repo.as_user(user_id, fn ->
        with {:ok, connection} <- fetch_connection(user_id, provider) do
          Repo.delete(connection)
        end
      end)

    result
  end
end
