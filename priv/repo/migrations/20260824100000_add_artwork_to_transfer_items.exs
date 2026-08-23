defmodule OnePlaylist.Repo.Migrations.AddArtworkToTransferItems do
  @moduledoc """
  Cover art on the report, for the services that give it away.

  Denormalized for the same reason the titles beside them are: redisplaying a
  decision already made must not cost a provider call per row.

  Nullable and expected to stay null for most rows. A Subsonic destination has
  no artwork this application can use — its cover endpoint wants credentials on
  the request — and a file source has none at all. See the `:artwork` capability
  on `OnePlaylist.Providers.Adapter`.
  """

  use Ecto.Migration

  def change do
    alter table(:transfer_items) do
      add :source_artwork_url, :text
      add :destination_artwork_url, :text
    end
  end
end
