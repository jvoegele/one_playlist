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

  > #### Inert for TIDAL sources, for now {: .info}
  >
  > Verified against the live API on 2026-08-22: TIDAL exposes `barcodeId` on
  > the album resource, but neither the track resource nor the track-to-album
  > relationship carries the track's position within the album. Getting it
  > needs a separate request per album, against
  > `/albums/{id}/relationships/items`.
  >
  > So `OnePlaylist.Music.Track.track_number/0` is `nil` for TIDAL and this rung
  > does not fire for TIDAL sources. It is implemented and tested regardless,
  > because the barcode half is already populated and the next provider added
  > may well supply the position — Spotify and Apple Music both do. Until then
  > the barcode still earns its keep as corroboration in the text and fuzzy
  > rungs, where agreement on the release raises confidence in a text match.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track

  @impl true
  def strategy, do: :upc_position

  @impl true
  def score(source, candidate)

  def score(
        %Track{album_upc: source_upc, track_number: source_number} = source,
        %Track{album_upc: candidate_upc, track_number: candidate_number} = candidate
      )
      when is_binary(source_upc) and is_binary(candidate_upc) and
             is_integer(source_number) and is_integer(candidate_number) do
    barcode = Signals.normalize_barcode(source_upc)

    same_release? = barcode != nil and barcode == Signals.normalize_barcode(candidate_upc)
    same_position? = source_number == candidate_number and same_volume?(source, candidate)

    if same_release? and same_position? do
      {1.0, [upc: barcode, volume: volume(source), track_number: source_number]}
    end
  end

  def score(_source, _candidate), do: nil

  defp same_volume?(source, candidate), do: volume(source) == volume(candidate)

  # A release that does not say which disc a track is on has one disc.
  defp volume(%Track{volume_number: nil}), do: 1
  defp volume(%Track{volume_number: volume}), do: volume
end
