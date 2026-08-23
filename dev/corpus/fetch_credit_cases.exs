# Turns the harvested credits into replayable cases.
#
#     bin/remote dev/corpus/fetch_credit_cases.exs
#
# For each source track, asks TIDAL the same text question the engine would ask
# and records everything it was offered. The **ISRC is withheld from the
# source**, exactly as `match_rate.exs` withholds it, so the identifier rung
# cannot answer trivially — and it becomes the oracle instead: the right answer
# is whichever candidate carries it.
#
# ## Where the labels come from
#
#   * `%{"match" => provider_id}` — a candidate carried the source's ISRC. No
#     judgment needed; this is ground truth.
#   * `"unreviewed"` — either the source has no ISRC, or none of the candidates
#     carried it. The second case is *not* the same as "should decline": TIDAL
#     may hold the recording under a reissue's ISRC, which is exactly the bug
#     `Tidal.by_isrc/4` was fixed for. A person has to look.
#
# Nothing here decides that a case *should decline*. That label is a judgment
# and is only ever written by hand.

alias OnePlaylist.Providers
alias OnePlaylist.Providers.Tidal
alias OnePlaylist.Music.Track

# The connection is looked up rather than passed in. `bin/remote` evaluates this
# on the *server* node, so `System.get_env/1` reads that node's environment and
# not the shell's — an environment variable set beside the command never
# arrives. A dev machine has one TIDAL connection, so finding it is both simpler
# and harder to get wrong.
import Ecto.Query

# Through `fetch_usable_connection/2`, not a raw query: it refreshes a token
# that is close to expiry. Reading the row directly works right up until the
# hour it does not, and then every search fails with "Expired token" and the
# corpus quietly comes back empty.
owner =
  OnePlaylist.Repo.one!(
    from c in OnePlaylist.Providers.Connection,
      where: c.provider == :tidal and c.status == :active,
      select: c.user_id,
      limit: 1
  )

{:ok, connection} = Providers.fetch_usable_connection(owner, :tidal)

sources = "dev/corpus/credit_sources.json" |> File.read!() |> Jason.decode!()

capture = fn track ->
  %{
    "provider_id" => track.provider_id,
    "isrc" => track.isrc,
    "title" => track.title,
    "version" => track.version,
    "album" => track.album,
    "album_upc" => track.album_upc,
    "artists" => track.artists,
    "duration_seconds" => track.duration_seconds
  }
end

cases =
  Enum.map(sources, fn source ->
    # The ISRC is deliberately absent here. It is the oracle, not an input.
    query =
      Track.from_map(%{
        "provider" => "file",
        "provider_id" => "s",
        "isrc" => nil,
        "title" => source["title"],
        "album" => source["album"],
        "artists" => [source["artist"]],
        "duration_seconds" => source["duration_seconds"]
      })

    candidates =
      try do
        case Tidal.search_tracks(connection, query, limit: 10) do
          {:ok, tracks} -> Enum.map(tracks, capture)
          {:error, _reason} -> []
        end
      rescue
        _error -> []
      end

    truth = source["isrc"] && String.upcase(source["isrc"])
    hit = truth && Enum.find(candidates, &(&1["isrc"] == truth))

    Map.merge(source, %{
      "candidates" => candidates,
      "expect" => if(hit, do: %{"match" => hit["provider_id"]}, else: "unreviewed")
    })
  end)

File.write!("dev/corpus/credit_cases.json", Jason.encode!(cases, pretty: true))

%{
  cases: length(cases),
  self_labelled: Enum.count(cases, &is_map(&1["expect"])),
  unreviewed: Enum.count(cases, &(&1["expect"] == "unreviewed")),
  no_candidates_offered: Enum.count(cases, &(&1["candidates"] == []))
}
