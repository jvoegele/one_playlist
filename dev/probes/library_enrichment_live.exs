# Enrichment against the real MusicBrainz, on recordings already in the dev
# library.
#
# Read-mostly with respect to MusicBrainz — it only reads — and it writes only
# to `library_recordings`, filling in fields that are `nil`. Nothing is
# overwritten, which is `enrich/1`'s postcondition rather than this script's
# promise.
#
# Six recordings at one request a second, so it takes roughly fifteen seconds.
alias OnePlaylist.Library.Enrichment
alias OnePlaylist.Library.Recording
alias OnePlaylist.Repo

import Ecto.Query

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

summarise = fn %Recording{} = r ->
  %{
    title: r.title,
    isrc: r.isrc,
    mbid: r.musicbrainz_recording_id,
    album: r.album,
    upc: r.album_upc,
    seconds: r.duration_seconds,
    artwork: r.artwork_url && "yes"
  }
end

try do
  # Three that carry an ISRC and three that do not, so both halves of the
  # algorithm are exercised — the identifier path and the search-and-score one.
  with_isrc =
    Recording
    |> where([r], not is_nil(r.isrc) and is_nil(r.musicbrainz_recording_id))
    |> limit(3)
    |> Repo.all()

  without_isrc =
    Recording
    |> where([r], is_nil(r.isrc))
    |> limit(3)
    |> Repo.all()

  enrich = fn recordings ->
    Enum.map(recordings, fn recording ->
      case Enrichment.enrich(recording) do
        {:ok, enriched} ->
          %{before: summarise.(recording), after: summarise.(enriched)}

        {:error, reason} ->
          %{before: summarise.(recording), error: inspect(reason)}
      end
    end)
  end

  identified = enrich.(with_isrc)
  searched = enrich.(without_isrc)

  gained = fn results ->
    Enum.count(results, &(&1[:after] && &1.after.mbid && is_nil(&1.before.mbid)))
  end

  overwritten =
    Enum.count(identified ++ searched, fn
      %{before: before, after: aft} ->
        Enum.any?([:isrc, :album, :upc, :seconds], fn field ->
          before[field] && aft[field] != before[field]
        end)

      _errored ->
        false
    end)

  %{
    from_isrc: identified,
    from_search: searched,
    identified_by_isrc: "#{gained.(identified)}/#{length(identified)}",
    identified_by_search: "#{gained.(searched)}/#{length(searched)}",
    verdict:
      cond do
        with_isrc == [] and without_isrc == [] ->
          "nothing in the library to enrich"

        overwritten > 0 ->
          "#{overwritten} recording(s) had an existing value replaced — enrichment must only fill gaps"

        true ->
          "OK — gaps filled, nothing overwritten"
      end
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
