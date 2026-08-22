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

  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionNotFound
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Repo

  use Errata

  @type user_id :: Ecto.UUID.t()

  @doc "Lists a user's connections, most recently connected first."
  @spec list_connections(user_id()) :: [Connection.t()]
  def list_connections(user_id) do
    Connection
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Fetches one connection.

  Returns `{:error, %ConnectionNotFound{}}` rather than `nil` so the failure
  carries the provider and user it was looking for into whatever logs it.
  """
  @spec fetch_connection(user_id(), Connection.provider()) ::
          {:ok, Connection.t()} | {:error, ConnectionNotFound.t()}
  def fetch_connection(user_id, provider) do
    case Repo.get_by(Connection, user_id: user_id, provider: provider) do
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

  It does **not** refresh an expired access token — refreshing needs an HTTP
  call to the provider, which belongs behind `ExternalService`, in the
  provider adapter. This answers the question the adapter asks first.
  """
  @spec fetch_usable_connection(user_id(), Connection.provider()) ::
          {:ok, Connection.t()}
          | {:error, ConnectionNotFound.t() | ConnectionUnusable.t()}
  def fetch_usable_connection(user_id, provider) do
    with {:ok, connection} <- fetch_connection(user_id, provider) do
      if Connection.usable?(connection) do
        {:ok, connection}
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

    %Connection{}
    |> Connection.changeset(attrs)
    |> Repo.insert(
      # Without `returning: true` an upsert hands back the id Ecto generated
      # client-side rather than the id of the row that actually exists, so a
      # reconnect would return a struct whose primary key matches nothing.
      returning: true,
      on_conflict:
        {:replace,
         [
           :provider_user_id,
           :display_name,
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
  Replaces the tokens on a connection after a successful refresh.

  Clears the failure counters for the same reason `connect/3` does.
  """
  @spec record_refresh(Connection.t(), map()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def record_refresh(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(
      Map.merge(Map.new(attrs), %{
        last_refreshed_at: DateTime.utc_now(),
        status: :active,
        last_error: nil,
        consecutive_failures: 0
      })
    )
    |> Repo.update()
  end

  @doc """
  Records a failed refresh.

  `status` is only moved off `:active` when the provider told us the grant is
  dead. A transient failure leaves the connection active and merely increments
  the counter, so a provider outage does not mass-disconnect every user — which
  would turn a ten-minute upstream blip into a re-authorization campaign.
  """
  @spec record_failure(Connection.t(), Exception.t()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(%Connection{} = connection, error) do
    status =
      if Errata.is_error(error) and not Errata.retryable?(error),
        do: :reauth_required,
        else: connection.status

    connection
    |> Connection.changeset(%{
      status: status,
      last_error: Exception.message(error),
      consecutive_failures: connection.consecutive_failures + 1
    })
    |> Repo.update()
  end

  @doc """
  Connections whose access token expires within `skew_seconds`.

  This is the refresh scheduler's query. Only `:active` connections are
  considered — one already needing re-authorization cannot be fixed by us.
  """
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

  @doc "Removes a connection, revoking this application's access locally."
  @spec disconnect(user_id(), Connection.provider()) ::
          {:ok, Connection.t()} | {:error, ConnectionNotFound.t()}
  def disconnect(user_id, provider) do
    with {:ok, connection} <- fetch_connection(user_id, provider) do
      Repo.delete(connection)
    end
  end
end
