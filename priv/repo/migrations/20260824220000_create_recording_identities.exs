defmodule OnePlaylist.Repo.Migrations.CreateRecordingIdentities do
  use Ecto.Migration

  @moduledoc """
  Where a recording is known, at every service it has been located at.

  `docs/reference/domain.md` §5's L5, and the table §2 asks for when it ends by
  noting that a resolution `(source_service, source_id) → (dest_service,
  dest_id, confidence)` is "the asset that compounds" and is currently thrown
  away when a transfer finishes.

  ## Why it hangs off a recording rather than off a pair

  A pairwise cache — TIDAL id to Navidrome id — is simpler and is the wrong
  shape twice over. It grows with the *square* of the number of services, and it
  has nowhere to put the things that make an identity worth trusting: an ISRC
  that enrichment found, a MusicBrainz id, a correction a user made by hand.
  Those attach to a recording.

  So `library_recordings` is the hub. A transfer between two services neither of
  which is the library still teaches it both ids, and a later transfer *out of*
  the library gets them for free.

  ## Ownerless, like the recordings it names

  Takes the shape from `create_catalogue_release_lookups`: readable by any
  signed-in user, written only by the application. That a recording exists at
  TIDAL under a given id is a fact about the world's music rather than about
  anybody's library, and it is worth exactly as much to every user.

  ## The snapshot columns are not denormalization for speed

  `title`, `artists`, `album`, `artwork_url` and `duration_seconds` are a copy of
  what the destination called the track when it was last seen. They are here
  because no adapter has a *fetch one track by id* callback, so without them a
  recalled identity could name a track but not describe it — and a transfer
  report has to show what it matched to. With them, recalling an identity costs
  **no request at all**, which is the whole economic claim of L5.

  A stale snapshot is the price. It is bounded: `confirm_written/5` reads the
  destination's playlist after every run, so an id that has stopped working
  surfaces as a written track that is not there.

  ## One answer per service

  Unique on `(recording_id, provider)`. A recording may genuinely exist at a
  service under several ids — different pressings of the same album — but a
  transfer needs *an* id rather than all of them, and a spine that answers with
  a list has not answered. Better evidence replaces weaker; see
  `OnePlaylist.Library.Identities.record/3`.
  """

  def up do
    create table(:recording_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recording_id,
          references(:library_recordings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider, :text, null: false
      add :provider_id, :text, null: false

      # What the destination called it when last seen. See the moduledoc.
      add :title, :text
      add :artists, {:array, :text}, null: false, default: []
      add :album, :text
      add :artwork_url, :text
      add :duration_seconds, :integer

      # How this was learned, replayed when the identity is recalled so a report
      # says why two tracks correspond rather than merely that they do. Both are
      # `OnePlaylist.Matching`'s own vocabulary.
      add :strategy, :text, null: false
      add :score, :float, null: false

      # Not `inserted_at`/`updated_at`: the interesting dates are when this was
      # first learned and when it was last seen to still be true, and a `select`
      # that does not change either should not touch a timestamp.
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_confirmed_at, :utc_datetime_usec, null: false
    end

    # The same set `provider_connections` allows, minus `file` — a file has no
    # ids to remember. Written out rather than derived so that adding a provider
    # is a deliberate migration rather than a silent widening.
    execute """
            alter table public.recording_identities
              add constraint recording_identities_provider_check
              check (provider in ('tidal', 'subsonic', 'navidrome', 'library'))
            """,
            "alter table public.recording_identities drop constraint recording_identities_provider_check"

    # The spine's only lookup: "where is this recording, at that service?"
    create unique_index(:recording_identities, [:recording_id, :provider])

    # The reverse question, for a source track arriving from a service: "which
    # recording is this?" Answered without a scan when a transfer teaches the
    # spine about ids it has seen before.
    create index(:recording_identities, [:provider, :provider_id])

    execute "alter table public.recording_identities enable row level security",
            "alter table public.recording_identities disable row level security"

    execute "revoke all on table public.recording_identities from anon, authenticated",
            "grant all on table public.recording_identities to anon, authenticated"

    execute "grant select on table public.recording_identities to authenticated",
            "revoke select on table public.recording_identities from authenticated"

    execute """
            create policy "identities are public metadata" on public.recording_identities
              for select to authenticated using (true)
            """,
            ~s|drop policy "identities are public metadata" on public.recording_identities|
  end

  def down do
    drop table(:recording_identities)
  end
end
