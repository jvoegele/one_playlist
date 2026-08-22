defmodule OnePlaylist.Repo.Migrations.AddServerUrlToProviderConnections do
  use Ecto.Migration

  @moduledoc """
  Where a self-hosted provider actually lives.

  The first thing the second provider changed about a schema built for the
  first. Every hosted service has one API base URL, so TIDAL's is a constant in
  `config/config.exs`; a Subsonic server is **the user's own**, so its address
  is part of the authorization rather than part of the application.

  Nullable, because it is meaningless for a hosted provider — a TIDAL
  connection with a server URL would be a bug, not a customisation.

  Not encrypted, unlike the token columns beside it. A hostname is not a secret
  and encrypting it would make it unqueryable for no gain. The *password* for
  that server goes in `access_token`, which already is encrypted.
  """

  def up do
    alter table(:provider_connections) do
      add :server_url, :text
    end

    execute """
            alter table public.provider_connections
              add constraint provider_connections_server_url_scheme_check
              check (server_url is null or server_url ~* '^https?://')
            """,
            "alter table public.provider_connections drop constraint provider_connections_server_url_scheme_check"
  end

  def down do
    alter table(:provider_connections) do
      remove :server_url
    end
  end
end
