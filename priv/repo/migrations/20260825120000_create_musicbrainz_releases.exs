defmodule OnePlaylist.Repo.Migrations.CreateMusicbrainzReleases do
  use Ecto.Migration

  @moduledoc """
  A release, with its track list, kept because releases barely change.

  ## What it is for

  Every strategy in the matching ladder searches by **track title** and treats
  the album as corroboration. For a live bootleg that weighting is backwards:
  *Live: 05-03-03 - State College, Pennsylvania* is enormously more distinctive
  than *[improvisation]*, and a title that is not a name carries no signal at
  all. The answer is to search the *release* and look for our title among its
  tracks — see `docs/reference/domain.md` §3 and the backlog in `CLAUDE.md`.

  What stopped that being built was cost: a lookup per candidate release, and a
  bootleg release runs to 39 tracks. One probe timed out at ten seconds fetching
  a single one. This table is what makes it affordable — fetch a show once, and
  every other track from that same album is answered locally.

  ## Why nothing here expires

  The other MusicBrainz tables prune, and it would be easy to copy that without
  thinking. They prune **negatives only** — `where recording_mbid is null`, on a
  thirty-day TTL — because "MusicBrainz has never heard of this ISRC" is a
  statement about *now*, and today's gap is next month's entry.

  A release fetched by its own MBID cannot be a negative. And what it says is
  close to immutable: release `fd029255` has those thirty-nine tracks in that
  order, and will next year. So there is nothing here that a TTL would be
  correcting, and deleting a row costs a re-fetch against a service that allows
  one request a second.

  `looked_up_at` is therefore for **refreshing**, not for pruning: re-fetch a
  release only when it is both stale and actually being consulted, which is the
  same cost paid strictly less often.

  Growth is not a reason either. A release with forty tracks is a few kilobytes;
  a hundred thousand of them is a few hundred megabytes, and this application
  will not see a hundred thousand distinct releases for a very long time. An
  eviction rule for rows nobody reads is a real idea and a premature one — it
  wants a measurement first, and there is nothing yet to measure.

  ## Ownerless, like `catalogue_release_lookups` and the other lookups

  These rows belong to nobody. "This release contains these recordings" is true
  for every user, so the `auth.uid()` policy shape does not apply and there is
  nothing to scope. `anon` and `authenticated` are granted nothing at all: a
  client able to write here could tell the matching engine that any recording
  appears on any album.

  ## A document rather than normalized tables

  `tracks` is `jsonb` and deliberately not a `musicbrainz_release_tracks` table.
  Nothing joins to this — it is consulted, read whole, and compared against in
  Elixir — and normalizing it would invite treating a cache as a source of
  truth. `library_recordings` is where a recording becomes a fact about this
  application; this is a copy of somebody else's catalogue.
  """

  def change do
    create table(:musicbrainz_releases, primary_key: false) do
      # MusicBrainz's own id, which is the only key that means anything here.
      add :mbid, :uuid, primary_key: true

      add :title, :text, null: false
      add :artist_credit, :text
      add :barcode, :text
      # Kept as text: MusicBrainz dates are partial — "1994", "2003-05" and
      # "2003-05-03" are all valid, and a date column would have to invent the
      # missing parts.
      add :date, :text

      # The release *group* — the album across all its pressings. Cover art is
      # keyed on this rather than on the release, because which pressing won a
      # barcode has nothing to do with which one somebody scanned.
      add :release_group_mbid, :uuid
      add :release_group_title, :text
      add :primary_type, :text
      # Reads `["Live"]` for an official bootleg, which is what
      # `Music.Track.live_release?` is derived from.
      add :secondary_types, {:array, :text}, null: false, default: []

      # `[{"position", "title", "recording_mbid", "length_ms"}]`. The reason the
      # table exists: "is our title among this release's tracks" is the question
      # release-first search asks, and this is the only column that answers it.
      # `:map` is Ecto's name for `jsonb`; the value here is a **list** of track
      # objects. The default therefore has to be written as a fragment: Ecto
      # renders `default: %{}` as an empty *object*, which will not load into
      # `{:array, :map}`, and rejects `default: []` outright for a non-array
      # column.
      add :tracks, :map, null: false, default: fragment("'[]'::jsonb")

      # For refreshing a stale release that is being consulted — never for
      # deleting one. See the moduledoc.
      add :looked_up_at, :utc_datetime_usec, null: false
    end

    # "Which releases did we already fetch for this album?" — cover art asks it,
    # and so does anything reasoning about an album rather than a pressing.
    create index(:musicbrainz_releases, [:release_group_mbid])

    # "Have we seen a release called this?" Case-folded because MusicBrainz's
    # capitalisation and a tagger's rarely agree, and this is a lookup rather
    # than a similarity — narrowing is its job and deciding is the ladder's.
    execute "create index musicbrainz_releases_title_index on public.musicbrainz_releases (lower(title))",
            "drop index if exists musicbrainz_releases_title_index"

    # --- Authorization -------------------------------------------------------
    #
    # The ownerless shape: protection by *absence of grant*, since there is no
    # owner to compare against. See `docs/reference/supabase.md`.
    execute "alter table public.musicbrainz_releases enable row level security",
            "alter table public.musicbrainz_releases disable row level security"

    execute "revoke all on table public.musicbrainz_releases from anon, authenticated",
            "grant all on table public.musicbrainz_releases to anon, authenticated"
  end
end
