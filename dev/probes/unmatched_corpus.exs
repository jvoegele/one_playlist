# Why each hand-labelled recording was not found.
#
# `dev/Unmatched PJ Favorites.csv` says which MusicBrainz recording each
# unmatched library track *should* have resolved to. This asks, for each one,
# the only question that decides what to fix:
#
#   * **Not offered** — the search never returned the right recording. A scoring
#     change cannot help; the query is wrong.
#   * **Offered and declined** — it was in the candidate list and did not reach
#     the threshold. A query change cannot help; the ladder is wrong, or the
#     stored metadata is too thin to corroborate anything.
#
# The distinction is the one `CLAUDE.md` already draws for the TIDAL corpus
# ("search recall, not the ladder") and it has never been asked of MusicBrainz.
#
# Read-only. Up to three requests per row at one a second.
alias OnePlaylist.Library.Recording
alias OnePlaylist.Matching
alias OnePlaylist.Matching.Confidence
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.MusicBrainz.Client
alias OnePlaylist.Repo

import Ecto.Query

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

ceiling = elem(Confidence.band(:text), 1)

lead = fn
  nil -> nil
  credit -> credit |> String.split(~r/\s*[,&\/+]\s*/u, parts: 2) |> List.first() |> String.trim()
end

mbid = fn
  "" -> nil
  url -> url |> String.split("/") |> List.last()
end

# The same query `Enrichment.by_name/1` builds: the parsed title, the whole
# credit, and the credit's first name when that comes back empty.
search = fn recording ->
  title = Normalize.title(recording.title).title
  credit = List.first(recording.artists || [])

  case Client.search_recordings(title, credit, limit: 25) do
    {:ok, []} ->
      case Client.search_recordings(title, lead.(credit), limit: 25) do
        {:ok, retried} -> retried
        {:error, _} -> []
      end

    {:ok, found} ->
      found

    {:error, _} ->
      []
  end
end

try do
  rows =
    "dev/Unmatched PJ Favorites.csv"
    |> File.read!()
    |> NimbleCSV.RFC4180.parse_string()
    |> Enum.map(fn [title, artist, album, recording, release, group] ->
      %{title: title, artist: artist, album: album, want: mbid.(recording),
        release: mbid.(release), group: mbid.(group)}
    end)

  results =
    Enum.map(rows, fn row ->
      stored =
        Recording
        |> where([r], r.title == ^row.title and r.album == ^row.album)
        |> limit(1)
        |> Repo.one()

      cond do
        is_nil(stored) ->
          %{title: row.title, verdict: "not in the library"}

        is_nil(row.want) ->
          %{title: row.title, verdict: "labelled as having no MusicBrainz recording"}

        true ->
          candidates = search.(stored)
          offered = Enum.find(candidates, &(&1.provider_id == row.want))

          scored =
            if offered do
              case Matching.rank(Recording.to_track(stored), [offered], threshold: ceiling) do
                [%{score: score, strategy: strategy} | _] ->
                  "#{Float.round(score, 4)} via #{strategy}"

                [] ->
                  "vetoed"
              end
            end

          %{
            title: row.title,
            stored: "isrc=#{stored.isrc || "-"} secs=#{stored.duration_seconds || "-"} album=#{stored.album}",
            candidates: length(candidates),
            verdict:
              if(offered,
                do: "OFFERED and declined — scored #{scored}",
                else: "NOT OFFERED — the search never returned it"
              ),
            wanted:
              if(offered,
                do: "#{offered.title} · #{Enum.join(offered.artists, ", ")} · #{offered.album} · #{offered.duration_seconds}s · isrc=#{offered.isrc || "-"}",
                else: nil
              )
          }
      end
    end)

  %{
    threshold: ceiling,
    offered: Enum.count(results, &String.starts_with?(&1.verdict, "OFFERED")),
    not_offered: Enum.count(results, &String.starts_with?(&1.verdict, "NOT OFFERED")),
    detail: results
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
