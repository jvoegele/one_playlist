defmodule OnePlaylist.Library.Albums do
  @moduledoc """
  Making an album agree with itself about which release it is.

  `OnePlaylist.Library.Enrichment` resolves one **recording** at a time, and an
  album is not one recording. Its moduledoc says where that runs out; this is
  the piece it names.

  ## Why a track-at-a-time rule cannot get there

  Enrichment's rule 1 — "an album agrees with itself" — reads a sibling's
  chosen release and adopts it when this recording appears on it. That makes an
  album converge *if the first track happened to pick a release the rest can
  live with*, and nothing ever revisits the choice when it did not.

  Measured on the dev library, that is exactly what went wrong. **Riot Act** is
  the clean case: MusicBrainz lists `15b30100` against all ten of its tracks and
  `2a7cdc41` against eight. `1/2 Full` was enriched first, had no sibling to
  inherit from, and `choose_release/2` picked `2a7cdc41`. The next seven
  inherited it; `Save You` and `I Am Mine` do not appear on it, fell through to
  their own best, and got `15b30100`. A release every track could have agreed on
  was passed over on arrival order alone, and the album ended up holding two
  barcodes.

  *Ten Redux* is the same failure inverted — `1989eada` is listed against all
  six tracks, `bf590957` against two, and the first track drew `bf590957`.

  So the release an album should settle on is **the one that accounts for the
  most of its tracks**, and no track knows that. Only the album does.

  ## What it did

  Run over the dev library on 2026-08-25, against the eight albums that
  disagreed with themselves:

  | | |
  | --- | --- |
  | Albums resolved to a single release | **8 of 8** |
  | Whose chosen release covers the whole album | **8 of 8** |
  | Whose chosen release states a barcode | 7 of 8 (*Born in the U.S.A.* has no barcoded pressing among its candidates) |
  | Recordings moved | 35 |
  | Recordings that gained a release they had none for | 7 |
  | Extra MusicBrainz requests | 13, one per candidate release not already cached |

  `bin/remote dev/measure/album_agreement.exs` is the replay, and it now reports
  nothing to do. Re-run it after a backfill.

  ## How the album is resolved

  1. Take every identified recording of the album — same `album`, same primary
     credit.
  2. The candidates are the releases those recordings have **already settled
     on**. No search: enrichment has done the finding, and this is a
     disagreement between answers already in hand.
  3. Keep the candidates that are releases of this album, by the same
     `OnePlaylist.Matching.Normalize.same_album?/3` enrichment filters on. Two
     different albums sharing a title cannot mislead each other.
  4. Score each by **coverage** — how many of the album's recordings its track
     list accounts for — and take the widest. Ties go to the release that
     carries a barcode, then the earliest, then the lowest id.
  5. Write it to every recording it covers.

  Coverage is a union of two tests and needs to be, which had to be measured. A
  release's track list names a `recording_mbid`, so the exact test is free — but
  a remaster is a *different recording entity*, so it does not carry across
  pressings. `Ten Redux`'s winner names two of its six tracks by MBID and five
  by title; `Vs.`'s names thirteen of nineteen by MBID and all nineteen by
  title. Either test alone leaves an album split.

  The title test is an exact match after normalization and **nothing else**,
  which is narrower than it looks and was nearly written wrong. The obvious
  guard to add is a duration check, the way
  `Enrichment.tracks_named_like/2` has one. It does not belong here, because it
  answers a different question: a duration is evidence about *which recording*
  two entries are, and coverage is not asking that. It asks whether this
  **pressing carries this track**, and step 3 has already established that the
  pressing is a pressing of this album. If a release of *Vs.* lists a track
  called *Blood*, the album's *Blood* is on it.

  Measured, the guard also fails in practice on exactly the data it would have
  to be trusted with. Five of *Vs.*'s nineteen tracks were rejected by it, and
  in every case the library was wrong and MusicBrainz right — *Blood* stored as
  63 seconds against a true 2:51, *Rats* as 164 against 4:15. Those rows came
  from a CSV import, where a duration is whatever the exporting application
  wrote. Splitting an album over that is the tail wagging the dog.

  ## Correcting is not enriching, and this is the correcting one

  `Enrichment.enrich/1` may only fill gaps — a background job must not rewrite a
  user's metadata, and `only_filled_gaps?/2` is a postcondition proven by
  mutation. Resolving an album is the other kind of operation: it exists
  precisely to **replace** a release chosen wrongly.

  Rather than weaken enrichment's rule, this carries its own, stated the same
  way and just as narrow. `adopt/2` may write `musicbrainz_release_id` and
  `album_upc` and nothing else, and `only_adopted_the_release?/3` is the
  postcondition that says so. Enrichment's contract is untouched.

  `album_upc` is safe to replace here for the reason `Enrichment.reset/1` gives:
  a recording holding a `musicbrainz_release_id` got its barcode from that
  release, which is the nearest thing to provenance this schema has. A recording
  with a UPC and *no* release id got it from its source, and keeps it.

  ### So an album can still hold two barcodes, and that is the right answer

  Five of the dev library's albums do, after every one of them was settled on a
  single release. *The Joshua Tree* is the shape: both its tracks came from
  TIDAL, one arrived carrying TIDAL's own `00602517449398` and no MusicBrainz
  release beside it, and the other had no barcode at all and took the chosen
  release's `075679058126`.

  Replacing the first would be this application overwriting a service's own
  statement about its own catalogue, which is the thing `enrich/1` refuses to do
  and the reason that refusal is worth keeping. It is also not obviously an
  improvement even ignoring provenance: UPC+position matching *back* to TIDAL
  wants TIDAL's barcode.

  What this module owed the album was one **release**, and every album has one.
  A barcode disagreeing with it is a provenance problem — the schema records no
  source for a field — and the answer to it is a provenance model, not a wider
  licence here.

  `artwork_url` is not touched at all, and needs no rule. Cover art already
  comes from the **release group** — the album across all its pressings — so
  every candidate here answers the question identically. That is why the albums
  that disagreed about a barcode still agreed about their cover.

  ## What it costs

  At most one MusicBrainz request per candidate release, and only on a release
  this application has never fetched. `OnePlaylist.MusicBrainz.release/1` is
  read-through into `musicbrainz_releases`, where nothing expires — so an album
  resolved a second time costs nothing at all.
  """

  use Bond

  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.MusicBrainz
  alias OnePlaylist.MusicBrainz.Release
  alias OnePlaylist.Repo

  import Ecto.Query

  @type album :: {String.t(), String.t() | nil}

  @type resolution :: %{
          album: String.t(),
          artist: String.t() | nil,
          release: Release.t() | nil,
          recordings: non_neg_integer(),
          covered: non_neg_integer(),
          changed: non_neg_integer()
        }

  # Everything `adopt/2` is allowed to differ on. `updated_at` is Ecto's and
  # says nothing about the music.
  @writable [:musicbrainz_release_id, :album_upc]
  @bookkeeping [:updated_at]

  @doc """
  Every album whose recordings do not agree on a release.

  The work list. An album is keyed by its title and its **primary credit**,
  which is what keeps three unrelated *Greatest Hits* apart — measured here, the
  naive grouping by title alone reported nine disagreeing albums where there are
  eight, and the ninth was 2Pac, Sly & The Family Stone and Simon & Garfunkel
  counted as one record.

  A compilation whose tracks each carry their own artist is therefore never
  grouped, and this does not help it. That is the honest limit rather than a
  bug: those tracks genuinely have nothing but a title in common, and forcing
  them onto one release is the error this module exists to undo.
  """
  @spec spanning() :: [album()]
  def spanning do
    Recording
    |> where([r], not is_nil(r.album) and not is_nil(r.musicbrainz_recording_id))
    |> group_by([r], [r.album, fragment("?[1]", r.artists)])
    |> having([r], count(r.musicbrainz_release_id, :distinct) > 1)
    |> select([r], {r.album, fragment("?[1]", r.artists)})
    |> Repo.all()
  end

  @doc """
  Settles one album on one release, and reports what it did.

  `changed` counts the recordings whose release id actually moved, so a second
  run over a settled album reports zero and writes nothing.

  `release` is `nil` when no candidate survives — an album whose recordings hold
  releases that turn out not to be releases of it, which is what a
  MusicBrainz-invented bucket like *Non-Album Tracks* looks like from here.
  Nothing is written in that case, deliberately: the tracks really do appear on
  unrelated releases and there is no album for them to agree about.
  """
  # No contract here, and that was checked rather than assumed. The law worth
  # stating — a release named in the result accounts for something — was written
  # here first as `release_earns_its_place`, and mutation proved it unreachable:
  # `choose/2`'s `covers_something` guards the identical bug one altitude down
  # and raises before this function returns. Two guards where one can never see
  # a bug the other misses is the redundancy `docs/reference/contracts.md`
  # warns about, so the law stays on `choose/2`, where it fires.
  @spec resolve(String.t(), String.t() | nil) :: resolution()
  def resolve(album, artist) when is_binary(album) do
    recordings = identified(album, artist)
    releases = recordings |> candidates() |> eligible(recordings)

    case choose(recordings, releases) do
      nil ->
        blank(album, artist, length(recordings))

      %Release{} = release ->
        covered = Enum.filter(recordings, &covers?(release, &1))

        changed =
          covered
          |> Enum.reject(&(&1.musicbrainz_release_id == release.mbid))
          |> Enum.count(&match?({:ok, _adopted}, adopt(&1, release)))

        %{
          album: album,
          artist: artist,
          release: release,
          recordings: length(recordings),
          covered: length(covered),
          changed: changed
        }
    end
  end

  @doc """
  Resolves every album in `spanning/0`, newest disagreement first.

  Written for a probe and for a console. There is no scheduled job behind it:
  an album disagreeing with itself is a consequence of enrichment's per-track
  rule, not a thing that decays, so it is worth running after a backfill rather
  than nightly.
  """
  @spec resolve_spanning() :: [resolution()]
  def resolve_spanning do
    Enum.map(spanning(), fn {album, artist} -> resolve(album, artist) end)
  end

  @doc """
  The release that accounts for the most of these recordings, or `nil`.

  Public so the moduledoc's rule 4 can be read against something, and so the
  choice can be measured without writing anything.

  `covers_something` is not implied by `nothing_covers_more`: a release can be
  maximal at zero coverage, which is precisely the case where an album has
  nothing to agree about and `nil` is the honest answer.
  """
  # No input can falsify these — the function chooses from the list it was handed
  # — so each is proven by mutation, applied alone and reverted:
  #
  #   * `chosen_from_the_candidates` — return the winner with a fresh `mbid`
  #   * `nothing_covers_more` — drop the `-` from `ranking/2`'s coverage term
  #   * `covers_something` — delete the `Enum.filter/2` below
  @post chosen_from_the_candidates: is_nil(result) or result in releases
  @post nothing_covers_more:
          is_nil(result) or
            Enum.all?(releases, &(coverage(&1, recordings) <= coverage(result, recordings)))
  @post covers_something: not is_nil(result) ~> (coverage(result, recordings) > 0)
  @spec choose([Recording.t()], [Release.t()]) :: Release.t() | nil
  def choose(recordings, releases) do
    releases
    |> Enum.filter(&(coverage(&1, recordings) > 0))
    |> Enum.sort_by(&ranking(recordings, &1))
    |> List.first()
  end

  @doc """
  How many of these recordings a release's track list accounts for.
  """
  @spec coverage(Release.t(), [Recording.t()]) :: non_neg_integer()
  def coverage(%Release{} = release, recordings) do
    Enum.count(recordings, &covers?(release, &1))
  end

  @doc """
  Whether a release's track list accounts for this recording.

  By MBID where MusicBrainz agrees the two are one recording, and otherwise by
  an exact normalized title. See the moduledoc for why one test alone is not
  enough, and why the title test carries no duration check.
  """
  @spec covers?(Release.t(), Recording.t()) :: boolean()
  def covers?(%Release{} = release, %Recording{} = recording) do
    tracks = List.wrap(release.tracks)

    named_by_mbid?(tracks, recording) or named_by_title?(tracks, recording)
  end

  @doc """
  Writes the album's release onto one recording.

  The correcting half, and the only function here that writes. See the
  moduledoc for why this is allowed to replace a value where `enrich/1` is not.

  `nothing_else_changed` is what stands in for
  `OnePlaylist.Library.Enrichment.only_filled_gaps?/2`, and the reason that
  contract did not have to be weakened to make album resolution possible. It is
  what keeps this operation's permission narrow enough to be worth granting: a
  background job that could rewrite a user's titles is exactly what `enrich/1`
  refuses to be, and the only difference here is a contract saying it cannot.
  """
  # `adopt/2` builds its own attributes, so no input can violate either. Proven
  # by mutation: a fresh `Ecto.UUID` for `release.mbid` fires the first, and
  # adding `title: "mutated"` to `attrs` fires the second.
  @post whenever(
          {:ok, adopted} <- result,
          release_adopted: adopted.musicbrainz_release_id == release.mbid,
          nothing_else_changed: only_adopted_the_release?(recording, adopted, release)
        )
  @spec adopt(Recording.t(), Release.t()) ::
          {:ok, Recording.t()} | {:error, Ecto.Changeset.t()}
  def adopt(%Recording{} = recording, %Release{} = release) do
    attrs = %{musicbrainz_release_id: release.mbid}

    attrs =
      case writable_upc(recording, release) do
        nil -> attrs
        upc -> Map.put(attrs, :album_upc, upc)
      end

    recording |> Recording.changeset(attrs) |> Repo.update()
  end

  @doc """
  Whether an adoption changed the release, the barcode, and nothing else.

  Public because `adopt/2` names it in a postcondition, and an assertion
  rendered into the documentation should reference something a reader can look
  up. The counterpart to `OnePlaylist.Library.Enrichment.only_filled_gaps?/2`,
  and deliberately shaped like it.

  A barcode may only become the release's own, and only where it was replacing
  one this application had written — see the moduledoc.
  """
  @spec only_adopted_the_release?(Recording.t(), Recording.t(), Release.t()) :: boolean()
  def only_adopted_the_release?(%Recording{} = before, %Recording{} = adopted, %Release{} = rel) do
    untouched =
      (Recording.__schema__(:fields) -- @writable) -- @bookkeeping

    Enum.all?(untouched, &(Map.fetch!(before, &1) == Map.fetch!(adopted, &1))) and
      adopted.musicbrainz_release_id == rel.mbid and
      adopted.album_upc in [before.album_upc, writable_upc(before, rel)]
  end

  # Every recording of this album that enrichment has identified. An
  # unidentified one is not this module's problem: it has no release to
  # disagree about, and `Enrichment.due/1` is what offers it again.
  defp identified(album, artist) do
    Recording
    |> where([r], r.album == ^album and not is_nil(r.musicbrainz_recording_id))
    |> artist_is(artist)
    |> Repo.all()
  end

  defp artist_is(query, nil), do: where(query, [r], is_nil(fragment("?[1]", r.artists)))
  defp artist_is(query, artist), do: where(query, [r], fragment("?[1]", r.artists) == ^artist)

  # Read-through, so this is free for a release already in `musicbrainz_releases`
  # and one request for one that is not.
  defp candidates(recordings) do
    recordings
    |> Enum.map(& &1.musicbrainz_release_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&MusicBrainz.release/1)
    |> Enum.reject(&is_nil/1)
  end

  # Rule 3. The same filter enrichment applies, for the same reason: a release
  # is only allowed to describe this album if it *is* this album.
  defp eligible(releases, []), do: releases

  defp eligible(releases, [%Recording{} = recording | _rest]) do
    Enum.filter(releases, fn release ->
      Normalize.same_album?(recording.album, release.title, artists: recording.artists)
    end)
  end

  # Widest coverage first; then a release that states a barcode, because that is
  # the field the disagreement was visible in and a release carrying one tells
  # us strictly more; then the earliest, then the lowest id so the answer is
  # deterministic rather than merely stable. A missing date sorts last for the
  # reason `Enrichment.ranking/2` gives — an undated release is usually a stub.
  defp ranking(recordings, %Release{} = release) do
    {-coverage(release, recordings), release.barcode in [nil, ""], release.date || "9999",
     release.mbid}
  end

  defp named_by_mbid?(tracks, %Recording{musicbrainz_recording_id: nil}) when is_list(tracks),
    do: false

  defp named_by_mbid?(tracks, %Recording{musicbrainz_recording_id: mbid}) do
    Enum.any?(tracks, &(&1["recording_mbid"] == mbid))
  end

  defp named_by_title?(_tracks, %Recording{title: title}) when title in [nil, ""], do: false

  defp named_by_title?(tracks, %Recording{} = recording) do
    ours = Normalize.title(recording.title).title

    Enum.any?(tracks, &(Normalize.title(&1["title"] || "").title == ours))
  end

  # A barcode this application may replace, or `nil` for "leave it alone". See
  # the moduledoc: a recording holding a release id got its UPC from that
  # release; one without got it from its source.
  defp writable_upc(%Recording{} = recording, %Release{barcode: barcode})
       when barcode not in [nil, ""] do
    if is_nil(recording.album_upc) or not is_nil(recording.musicbrainz_release_id),
      do: barcode
  end

  defp writable_upc(%Recording{}, %Release{}), do: nil

  defp blank(album, artist, recordings) do
    %{
      album: album,
      artist: artist,
      release: nil,
      recordings: recordings,
      covered: 0,
      changed: 0
    }
  end
end
