# Replays the whole library through `identify/1` without writing anything.
#
# Two questions, and the second is the one that decides whether a change ships:
#
#   1. How many of the twelve hand-labelled cases in
#      `dev/Unmatched PJ Favorites.csv` now resolve, and to the *right*
#      recording?
#   2. Does anything that resolves today stop resolving, or resolve to something
#      different? A recall improvement that quietly changes settled answers is a
#      regression wearing a better number.
#
# Read-only: it calls MusicBrainz and compares, and writes nothing.
alias OnePlaylist.Library.Recording
alias OnePlaylist.Matching
alias OnePlaylist.Matching.Confidence
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.MusicBrainz.Client
alias OnePlaylist.Repo

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

ceiling = elem(Confidence.band(:text), 1)

lead = fn
  nil -> nil
  credit -> credit |> String.split(~r/\s*[,&\/+]\s*/u, parts: 2) |> List.first() |> String.trim()
end

# The same shape `Enrichment.by_name/1` now has: release-qualified first, then
# title-and-artist, then the credit's first name.
identify = fn recording ->
  title = Normalize.title(recording.title).title
  credit = List.first(recording.artists || [])
  track = Recording.to_track(recording)

  pick = fn candidates, threshold ->
    case Matching.match(track, candidates, threshold: threshold) do
      {:ok, match} -> match.track.provider_id
      {:error, _} -> nil
    end
  end

  attempt = fn opts, threshold ->
    case Client.search_recordings(title, Keyword.get(opts, :artist, credit), opts) do
      {:ok, []} -> nil
      {:ok, candidates} -> pick.(candidates, threshold)
      {:error, _} -> nil
    end
  end

  # The question under test: a candidate found by a *release-qualified* query
  # has already had its album corroborated by MusicBrainz's own index, so the
  # ceiling — which exists to demand corroboration — may be asking for the same
  # evidence twice. Both answers are computed so they can be compared.
  strict = if recording.album, do: attempt.([album: recording.album], ceiling)
  relaxed = if recording.album, do: attempt.([album: recording.album], :high)

  %{
    strict: strict || attempt.([], ceiling) || attempt.([artist: lead.(credit)], ceiling),
    relaxed: relaxed || attempt.([], ceiling) || attempt.([artist: lead.(credit)], ceiling)
  }
end

wanted =
  "dev/Unmatched PJ Favorites.csv"
  |> File.read!()
  |> NimbleCSV.RFC4180.parse_string()
  |> Map.new(fn [title, _artist, album, recording, _release, _group] ->
    {{title, album}, if(recording == "", do: nil, else: recording |> String.split("/") |> List.last())}
  end)

try do
  labelled =
    wanted
    |> Enum.map(fn {{title, album}, want} ->
      case Repo.get_by(Recording, title: title, album: album) do
        nil ->
          %{title: title, verdict: "not in the library"}

        stored ->
          answers = identify.(stored)

          verdict = fn got ->
            cond do
              is_nil(want) and is_nil(got) -> "correctly declined"
              is_nil(want) and got -> "WRONG — matched something labelled absent"
              got == want -> "correct"
              is_nil(got) -> "missed"
              true -> "WRONG — matched #{got}"
            end
          end

          %{title: title, strict: verdict.(answers.strict), relaxed: verdict.(answers.relaxed)}
      end
    end)

  tally = fn key, prefix ->
    Enum.count(labelled, &String.starts_with?(Map.get(&1, key, ""), prefix))
  end

  %{
    of: length(labelled),
    at_the_ceiling: %{
      correct: tally.(:strict, "correct"),
      missed: tally.(:strict, "missed"),
      wrong: tally.(:strict, "WRONG")
    },
    release_qualified_at_high: %{
      correct: tally.(:relaxed, "correct"),
      missed: tally.(:relaxed, "missed"),
      wrong: tally.(:relaxed, "WRONG")
    },
    detail: labelled
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
