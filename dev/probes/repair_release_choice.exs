# One-off repair for the release-selection defect.
#
# Enrichment used to take whichever release MusicBrainz listed first, which is
# no order at all, so an album's tracks disagreed about their own barcode and
# cover. `OnePlaylist.Library.Enrichment.choose_release/2` now decides
# deliberately — but `enrich/1` never overwrites, so the wrong values stay until
# something clears them.
#
# `Enrichment.reset/1` is that something, and it is deliberately conservative:
# it clears a barcode and a cover only where `musicbrainz_release_id` proves
# enrichment chose the release they came from. **These rows predate that
# column**, so it is null on every one of them and `reset/1` alone would leave
# the wrong values in place.
#
# So this script clears those two columns itself, and it establishes the right
# to rather than assuming it. Both TIDAL and the CSV reader *can* supply a
# barcode, and TIDAL supplies artwork, so "enrichment wrote all of this" needed
# proving:
#
#   * The 7 `tidal`-origin recordings hold every non-MusicBrainz artwork URL in
#     the table and all carry a barcode. **They are excluded outright.**
#   * Of the 143 `file`-origin recordings, the 10 MusicBrainz never identified
#     have **no barcode and no artwork at all**. Had the imported CSV carried
#     either, those ten would have kept theirs. So on a `file` row both columns
#     are enrichment's work and nobody else's.
#
# That argument is about this table on this day, which is why this is a dated
# probe rather than a function in the library. `Enrichment.reset/1` is the
# general mechanism and is deliberately narrower.
#
# One consequence worth expecting: an album holding both `file` and `tidal`
# recordings may still show two barcodes afterwards. That is correct — the
# source's value wins over MusicBrainz's, which is the whole rule.
#
# Writes to `library_recordings` for albums whose tracks disagree, and enqueues
# them. Nothing else is touched.
alias OnePlaylist.Library.Enrichment
alias OnePlaylist.Library.EnrichmentWorker
alias OnePlaylist.Library.Recording
alias OnePlaylist.Repo

import Ecto.Query

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

try do
  # An album is inconsistent when its rows carry more than one barcode, or when
  # some have cover art and others do not. Either means the tracks resolved to
  # different releases.
  %{rows: albums} =
    Repo.query!("""
    select album
    from public.library_recordings
    where album is not null and enriched_at is not null
    group by album
    having count(distinct album_upc) > 1
        or (count(*) filter (where artwork_url is not null) between 1 and count(*) - 1)
    """)

  names = Enum.map(albums, &List.first/1)

  affected =
    Recording
    |> where([r], r.album in ^names and r.origin_provider == "file")
    |> select([r], r.id)
    |> Repo.all()

  # The wider clear this script exists to justify, and the reason the header
  # spends so long on provenance. `reset/1` handles the rest, including
  # `enriched_at`, which is what puts these back in front of `due/1`.
  {cleared, _returned} =
    Recording
    |> where([r], r.id in ^affected)
    |> Repo.update_all(set: [album_upc: nil, artwork_url: nil])

  reset = Enrichment.reset(affected)

  Enum.each(affected, &EnrichmentWorker.enqueue/1)

  %{
    inconsistent_albums: names,
    recordings: length(affected),
    columns_cleared: cleared,
    reset: reset,
    excluded_tidal_rows:
      Recording |> where([r], r.album in ^names and r.origin_provider != "file") |> Repo.aggregate(:count),
    note: "enqueued — roughly #{div(length(affected), 30)} minutes at one request a second"
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
