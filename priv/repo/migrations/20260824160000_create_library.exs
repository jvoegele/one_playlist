defmodule OnePlaylist.Repo.Migrations.CreateLibrary do
  use Ecto.Migration

  @moduledoc """
  Playlists this application holds itself — the library `docs/reference/domain.md`
  §5 describes, and the first place where One Playlist is somewhere a playlist
  *lives* rather than a pipe between two services that do the living.

  ## Two kinds of row, and conflating them is the mistake

  A **recording** is a fact about the world: this ISRC, this title, this
  duration, this id at TIDAL. It is the same answer for every user, stays true
  after they leave, and is the thing §2 calls the asset that compounds. So
  `library_recordings` belongs to nobody and takes the ownerless shape from
  `create_catalogue_release_lookups`.

  A **playlist** is the user's, and takes the `auth.uid()` shape from
  `create_transfers`. Nothing about who owns what leaks from sharing the
  recordings: membership lives in `library_playlist_items`, which is user-owned.

  ## The `:library` provider

  `provider_connections` gains a `library` row per user, because the library is
  reached through `OnePlaylist.Providers.Adapter` like any other service and
  every callback there takes a `%Connection{}`. It carries no credential — there
  is nothing to authorize against, the row *is* the authorization — which is why
  `OnePlaylist.Providers.Connection.usable?/1` grows a clause rather than
  demanding an access token this row will never have.

  That is the second stretch of that type, after Subsonic's password-with-no-
  expiry. A third should split the type rather than widen it again.
  """

  def up do
    # --- Recordings ----------------------------------------------------------

    create table(:library_recordings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The identifiers. `isrc` is canonical form — twelve upper-case
      # characters, per OnePlaylist.Music.Isrc — because it is what dedup
      # compares on and a lower-case one would silently miss.
      add :isrc, :text
      add :musicbrainz_recording_id, :uuid

      add :title, :text
      add :artists, {:array, :text}, null: false, default: []
      add :album, :text
      add :album_upc, :text
      add :track_number, :integer
      add :volume_number, :integer
      add :version, :text
      add :duration_seconds, :integer
      add :explicit, :boolean
      add :artwork_url, :text

      # Where this recording came from the first time it was seen. Not an
      # identity — the same recording arrives from several services — but worth
      # keeping, because it says which catalogue the metadata was written by.
      add :origin_provider, :text
      add :origin_provider_id, :text

      timestamps(type: :utc_datetime_usec)
    end

    # The dedup lookup. Partial because a recording without an ISRC cannot be
    # found this way and would only make the index bigger.
    create index(:library_recordings, [:isrc], where: "isrc is not null")

    # The other dedup lookup, for the tracks that have no ISRC at all — which
    # `docs/reference/domain.md` measures at roughly 40% of a real self-hosted
    # library. Lower-cased so it matches how the text rung compares.
    execute """
            create index library_recordings_title_index
              on public.library_recordings (lower(title))
              where title is not null
            """,
            "drop index public.library_recordings_title_index"

    execute """
            alter table public.library_recordings
              add constraint library_recordings_duration_check
              check (duration_seconds is null or duration_seconds >= 0)
            """,
            "alter table public.library_recordings drop constraint library_recordings_duration_check"

    # --- Playlists -----------------------------------------------------------

    create table(:library_playlists, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, on_delete: :delete_all, type: :uuid, prefix: "auth"),
        null: false

      add :name, :text, null: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:library_playlists, [:user_id])

    create table(:library_playlist_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :playlist_id,
          references(:library_playlists, on_delete: :delete_all, type: :binary_id),
          null: false

      # Denormalized onto the row so the policy below compares a column rather
      # than joining to the playlist per row — the same reason `transfer_items`
      # carries one, and the same Supabase RLS performance guidance.
      add :user_id, references(:users, on_delete: :delete_all, type: :uuid, prefix: "auth"),
        null: false

      add :recording_id,
          references(:library_recordings, on_delete: :restrict, type: :binary_id),
          null: false

      # Dense integers, and deliberately **not** unique. A playlist may hold the
      # same recording twice, and appending wants `max(position) + 1` rather
      # than a gap-free sequence. Reordering by hand is L2 and will want
      # fractional or lexicographic ranks instead — see §5 — which is a column
      # type change and cheap to make when there is something to reorder with.
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:library_playlist_items, [:playlist_id, :position])

    # --- The `:library` provider --------------------------------------------

    for {table, constraint} <- [
          {"provider_connections", "provider_connections_provider_check"},
          {"catalogue_release_lookups", "catalogue_release_lookups_provider_check"}
        ] do
      execute "alter table public.#{table} drop constraint #{constraint}",
              """
              alter table public.#{table}
                add constraint #{constraint}
                check (provider in ('spotify','apple_music','youtube_music','tidal','deezer','plex','jellyfin','navidrome','subsonic'))
              """

      execute """
              alter table public.#{table}
                add constraint #{constraint}
                check (provider in ('spotify','apple_music','youtube_music','tidal','deezer','plex','jellyfin','navidrome','subsonic','library'))
              """,
              "alter table public.#{table} drop constraint #{constraint}"
    end

    # One per existing user. `on conflict do nothing` so this is safe to re-run
    # and safe beside the application's own idempotent ensure — see
    # `OnePlaylist.Providers.ensure_library/1`, which covers users who sign up
    # after this migration.
    execute """
            insert into public.provider_connections
              (id, user_id, provider, provider_user_id, display_name, status, scopes,
               consecutive_failures, inserted_at, updated_at)
            select gen_random_uuid(), u.id, 'library', u.id::text, 'Your library',
                   'active', '{}', 0, now(), now()
              from auth.users u
            on conflict (user_id, provider) do nothing
            """,
            "delete from public.provider_connections where provider = 'library'"

    # --- Authorization -------------------------------------------------------

    # Recordings are ownerless. `create_catalogue_release_lookups` faced the
    # same question and took the other branch of it, granting nothing on the
    # grounds that the Phoenix application was its only consumer. That is not
    # true here: a library playlist is read *as the user*, through
    # `OnePlaylist.Repo.as_user/3`, so `authenticated` genuinely needs to select
    # these rows — and the reasoning that migration records for why a
    # `using (true)` policy is safe on non-user data applies exactly.
    #
    # Writes stay privileged. A client able to edit a shared recording could
    # rewrite what a track *is* for every user who holds it.
    execute "alter table public.library_recordings enable row level security",
            "alter table public.library_recordings disable row level security"

    execute "revoke all on table public.library_recordings from anon, authenticated",
            "grant all on table public.library_recordings to anon, authenticated"

    execute "grant select on table public.library_recordings to authenticated",
            "revoke select on table public.library_recordings from authenticated"

    execute """
            create policy "recordings are public metadata" on public.library_recordings
              for select to authenticated using (true)
            """,
            ~s|drop policy "recordings are public metadata" on public.library_recordings|

    # Playlists are the user's, and take the `auth.uid()` shape. Reads only:
    # writes go through the adapter, which runs privileged, exactly as the
    # transfer pipeline owns `transfers`.
    for table <- ~w(library_playlists library_playlist_items) do
      execute "alter table public.#{table} enable row level security",
              "alter table public.#{table} disable row level security"

      execute "revoke all on table public.#{table} from anon, authenticated",
              "grant all on table public.#{table} to anon, authenticated"

      execute "grant select on table public.#{table} to authenticated",
              "revoke select on table public.#{table} from authenticated"

      execute """
              create policy "own #{table} select" on public.#{table}
                for select to authenticated using ((select auth.uid()) = user_id)
              """,
              ~s|drop policy "own #{table} select" on public.#{table}|
    end
  end

  def down do
    execute "delete from public.provider_connections where provider = 'library'"

    drop table(:library_playlist_items)
    drop table(:library_playlists)
    drop table(:library_recordings)

    for {table, constraint} <- [
          {"provider_connections", "provider_connections_provider_check"},
          {"catalogue_release_lookups", "catalogue_release_lookups_provider_check"}
        ] do
      execute "alter table public.#{table} drop constraint #{constraint}"

      execute """
      alter table public.#{table}
        add constraint #{constraint}
        check (provider in ('spotify','apple_music','youtube_music','tidal','deezer','plex','jellyfin','navidrome','subsonic'))
      """
    end
  end
end
