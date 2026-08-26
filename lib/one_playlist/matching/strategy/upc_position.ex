defmodule OnePlaylist.Matching.Strategy.UpcPosition do
  @moduledoc """
  Rung 2: the same track of the same release, by barcode and position.

  This rung exists for the case rung 1 cannot handle: the same recording issued
  with a different ISRC per territory or per re-release. The barcode identifies
  the *release* rather than the recording, so it is not a match on its own — an
  album shares one barcode across all its tracks. Combined with a position
  within that release it is exact, and is scored accordingly.

  Position means volume *and* track number. Ignoring the volume would match
  track 3 of disc 1 to track 3 of disc 2 of the same release, which is a
  different recording with a plausible-looking justification — exactly the kind
  of wrong answer this project is built to avoid. A source with no volume is
  treated as disc 1, since single-disc releases usually omit it.

  ## Duration has to corroborate

  This is the one identifier rung that is not purely an identifier rung, and
  the exception is deliberate.

  A barcode identifies a release and a position identifies a slot on it, so in
  principle the pair is exact. In practice two services can list *different
  items* for one barcode — a bonus track included on one and not the other, a
  regional edition sharing a barcode — and then position 7 is a different
  recording on each. Rung 1 has no equivalent hazard: an ISRC names the
  recording itself, so there is nothing for two services to disagree about.

  Left unguarded, that disagreement produces a **confidently wrong answer at
  score 1.0**, which is strictly worse than a fuzzy near miss. A near miss is
  scored, thresholded and shown to a person; `1.0` is `:exact_upc` and goes
  straight through. So a duration that disagrees withdraws the claim, and the
  candidate falls through to the text and fuzzy rungs, which still see it and
  can still match it on its merits.

  A duration that is simply *unknown* on either side does not withdraw
  anything. Absent evidence is not contrary evidence — the same rule as
  `OnePlaylist.Matching.Similarity`.

  ## Where the data comes from

  Verified live on 2026-08-22. TIDAL exposes `barcodeId` on the album resource,
  and albums are findable by it (`/albums?filter[barcodeId]=…`), but neither
  the track resource nor the track-to-album relationship carries the track's
  position. That comes from `/albums/{id}/relationships/items`, where each item
  carries `meta.trackNumber` and `meta.volumeNumber` explicitly — see
  `OnePlaylist.Providers.Tidal.Mapper.tracks_from_album_items/2` for why
  reading them rather than counting list positions is load-bearing.

  So this rung fires for a TIDAL *destination* today. It stays inert for a
  TIDAL *source*, because a track read from a playlist has no position and
  giving it one would cost a request per album on the read path, paid whether
  or not ISRC later succeeds. Spotify and Apple Music both supply barcode and
  track number natively, so a source from either arrives ready.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Matching.Similarity
  alias OnePlaylist.Music.Barcode
  alias OnePlaylist.Music.Track

  @impl true
  def strategy, do: :upc_position

  # The moduledoc's two sections, made checkable. Both proven by mutation —
  # deleting `not contradicted?(duration)` fires the first, deleting
  # `same_release?` fires the second — and neither would fire until the tests
  # were written: this rung had a test for the disc number and none for either
  # law its moduledoc spends the most length on.
  @post_strengthen duration_never_contradicts:
                     not is_nil(result)
                     ~> (Similarity.duration_proximity(
                           source.duration_seconds,
                           candidate.duration_seconds
                         ) in [nil, 1.0])
  @post_strengthen only_on_the_same_release:
                     not is_nil(result)
                     ~> (not is_nil(Barcode.normalize(source.album_upc)) and
                           Barcode.normalize(source.album_upc) ==
                             Barcode.normalize(candidate.album_upc))
  @impl true
  def score(source, candidate)

  def score(
        %Track{album_upc: source_upc, track_number: source_number} = source,
        %Track{album_upc: candidate_upc, track_number: candidate_number} = candidate
      )
      when is_binary(source_upc) and is_binary(candidate_upc) and
             is_integer(source_number) and is_integer(candidate_number) do
    barcode = Barcode.normalize(source_upc)

    same_release? = barcode != nil and barcode == Barcode.normalize(candidate_upc)
    same_position? = source_number == candidate_number and same_volume?(source, candidate)
    duration = Similarity.duration_proximity(source.duration_seconds, candidate.duration_seconds)

    if same_release? and same_position? and not contradicted?(duration) do
      {1.0,
       [
         upc: barcode,
         volume: volume(source),
         track_number: source_number,
         duration: duration
       ]}
    end
  end

  def score(_source, _candidate), do: nil

  # Only a positive disagreement withdraws the claim. `nil` is unknown, not
  # contrary, and a full-marks proximity is agreement.
  defp contradicted?(nil), do: false
  defp contradicted?(proximity), do: proximity < 1.0

  defp same_volume?(source, candidate), do: volume(source) == volume(candidate)

  # A release that does not say which disc a track is on has one disc.
  defp volume(%Track{volume_number: nil}), do: 1
  defp volume(%Track{volume_number: volume}), do: volume
end
