defmodule OnePlaylist.MusicBrainz.Client do
  @moduledoc """
  Every MusicBrainz call this application makes.

  Each is a single request, which is the whole reason they are affordable at one
  request per second. Two serve matching, and three serve enrichment
  (`OnePlaylist.Library.Enrichment`).

  `isrc_family/2` — `GET /ws/2/isrc/{isrc}?inc=isrcs` — answers with every
  recording that ISRC names and, because of `inc=isrcs`, every *other* ISRC
  each of those recordings is known by:

      /ws/2/isrc/USJY50700001?fmt=json&inc=isrcs
      → recording ea8c7b4c…  "Setting Forth"
        isrcs: ["USJY50700001", "USJY51700100"]

  `works/2` — `GET /ws/2/work?query=…` — answers with the works a title names,
  which is where a classical catalogue number comes from when the title omits
  one.

  `search_recordings/3` and `recording/2` are enrichment's: find a recording by
  name, and learn everything about it in one lookup. Both document what was
  verified live rather than assumed, because both behave differently from the
  obvious guess.

  Cover art is **not** here. It belongs to an album rather than to a recording or
  a pressing, and the Cover Art Archive is a separate service — see
  `OnePlaylist.CoverArt.Client`.

  ## A contactful User-Agent is required

  MusicBrainz blocks clients that do not identify themselves, and the
  requirement is a *contact*, not a name. `config :one_playlist, OnePlaylist.MusicBrainz,
  user_agent: "..."` sets it; the default names this project and its repository
  so a MusicBrainz admin has somewhere to write.

  ## 404 is an answer

  An ISRC MusicBrainz has never heard of is not an error, and treating it as one
  would retry three times and then fail a lookup whose answer is simply "no".
  It returns `{:ok, nil}`.
  """

  use Bond

  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track
  alias OnePlaylist.MusicBrainz.Service

  require Logger

  @base_url "https://musicbrainz.org/ws/2"

  @default_user_agent "OnePlaylist/0.1 ( https://github.com/jvoegele/one_playlist )"

  @typedoc """
  What MusicBrainz knows about an ISRC: a recording, and every ISRC naming it.

  `nil` where MusicBrainz has no such ISRC.
  """
  @type family :: %{recording_mbid: String.t(), isrcs: [String.t()]} | nil

  @doc """
  Every ISRC that names the same recording as this one.

  The answer always contains the ISRC that was asked about, when there is an
  answer at all. That is not a formality: the caller compares candidate ISRCs
  against the family, and a family missing its own key would fail to match the
  very track it was looked up for.
  """
  # The precondition is the cache key rule as much as a correctness rule.
  # MusicBrainz is case-sensitive on this path and hyphenated input is a `400`,
  # so an unnormalized ISRC is a wasted request against a one-per-second budget
  # — and a second cache row for a fact already stored.
  @pre normalized_isrc: isrc == Isrc.normalize(isrc)
  @post whenever({:ok, %{isrcs: isrcs}} <- result, contains_the_key: isrc in isrcs)
  @spec isrc_family(String.t(), keyword()) :: {:ok, family()} | {:error, Exception.t()}
  def isrc_family(isrc, opts \\ []) do
    Service.call(fn -> request(isrc, opts) end)
  end

  defp request(isrc, opts) do
    [
      base_url: @base_url,
      url: "/isrc/#{isrc}",
      params: [fmt: "json", inc: "isrcs"],
      headers: [{"user-agent", user_agent()}],
      receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
    ]
    |> Keyword.merge(Application.get_env(:one_playlist, :musicbrainz_req_options, []))
    |> Req.new()
    |> Req.get()
    |> handle(isrc)
  end

  @doc """
  Titles of the works MusicBrainz thinks a query names.

  Returned as *titles* rather than parsed numbers because that is where the
  numbers are: MusicBrainz answers "Brandenburg Concerto no. 2 Bach" with
  *Brandenburgisches Konzert Nr. 2 F-Dur, BWV 1047*, and
  `OnePlaylist.Music.Work.parse/1` reads a catalogue number out of a title
  already. Handing the title back means one parser rather than two.

  Only the strongly-scoring results. MusicBrainz answers every query with
  something — a search for "Woo" returns 48,000 works — so a score floor is the
  difference between an answer and noise.
  """
  @spec works(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def works(query, opts \\ []) when is_binary(query) do
    Service.call(fn -> work_request(query, opts) end)
  end

  # 80 keeps the exact and near-exact hits and drops the rest. Measured against
  # a real library: at this floor MusicBrainz supplied a usable number for the
  # classical titles that carried none and stayed silent on the pop titles that
  # reached it by accident.
  @score_floor 80

  defp work_request(query, opts) do
    [
      base_url: @base_url,
      url: "/work",
      params: [query: query, fmt: "json", limit: 5],
      headers: [{"user-agent", user_agent()}],
      receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
    ]
    |> Keyword.merge(Application.get_env(:one_playlist, :musicbrainz_req_options, []))
    |> Req.new()
    |> Req.get()
    |> handle_works()
  end

  @doc """
  Recordings matching a title and artist, as candidate tracks.

  For the case an ISRC cannot answer: a recording that arrived from a file with
  a title and an artist and nothing else. Returns `OnePlaylist.Music.Track`
  structs rather than MusicBrainz's JSON, because what happens to them next is
  that they are scored by `OnePlaylist.Matching` like candidates from any other
  service — see `OnePlaylist.Library.Enrichment` for why that is not a
  convenience but the safeguard.

  ## The score is not a verdict

  Verified live on 2026-08-24: a search for *Corduroy* by *Pearl Jam* returns a
  **live bootleg** from Barcelona at **score 100**. MusicBrainz is scoring how
  well the text matched, which is not the same question as which recording was
  meant, and a caller that treated the top hit as the answer would attach the
  wrong identity — and then fill in that recording's ISRC, length and artwork,
  making the data worse rather than better.

  Search results also carry **no ISRCs** (verified: the field is absent, not
  empty), so an identity found this way still needs `recording/2` to be worth
  anything.

  ## `:album` is worth more than any other option here

  Measured against the twelve hand-labelled cases in
  `dev/Unmatched PJ Favorites.csv`. A prolific artist has more recordings of a
  title than a page can hold — Pearl Jam has a bootleg of nearly every song from
  nearly every show — so relevance alone buries the wanted one:

  | | Wanted recording found |
  | --- | --- |
  | Title and artist, ten results | 1 of 6 |
  | Title and artist, **a hundred** results | 3 of 6 |
  | Title, artist **and release** | **5 of 6**, four of them ranked first |

  A bigger page is the obvious fix and the weaker one: it found three, two of
  them at #3 and #84, where the ladder still has to pick correctly out of noise.
  Naming the release finds five and puts them at the top, because it is the one
  piece of corroborating evidence these tracks actually carry.
  """
  @spec search_recordings(String.t(), String.t() | nil, keyword()) ::
          {:ok, [Track.t()]} | {:error, Exception.t()}
  def search_recordings(title, artist, opts \\ []) when is_binary(title) do
    Service.call(fn -> recording_search(title, artist, opts) end)
  end

  defp recording_search(title, artist, opts) do
    query =
      [
        ~s(recording:"#{escape(title)}"),
        artist && ~s(artist:"#{escape(artist)}"),
        # Unquoted, deliberately. A stored album is routinely longer than the
        # release MusicBrainz holds — "Lost Dogs: Rarities and B Sides" against
        # "Lost Dogs", "Touring Band 2000 - Instrumentals" against "Touring Band
        # 2000" — and a phrase query would match in neither direction. Matching
        # on tokens finds it.
        opts[:album] && "release:(#{escape(opts[:album])})"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" AND ")

    [
      base_url: @base_url,
      url: "/recording",
      params: [query: query, fmt: "json", limit: Keyword.get(opts, :limit, 10)],
      headers: [{"user-agent", user_agent()}],
      receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
    ]
    |> Keyword.merge(Application.get_env(:one_playlist, :musicbrainz_req_options, []))
    |> Req.new()
    |> Req.get()
    |> handle_search()
  end

  defp handle_search({:ok, %{status: 503}}), do: :retry

  defp handle_search({:ok, %{status: 200, body: body}}) do
    {:ok, body |> Map.get("recordings", []) |> Enum.map(&to_track/1)}
  end

  defp handle_search({:ok, %{status: status}}) do
    Logger.warning("musicbrainz recording search returned #{status}")
    {:error, %RuntimeError{message: "musicbrainz returned #{status}"}}
  end

  defp handle_search({:error, _reason}), do: :retry

  @doc """
  Everything one recording is known by, in a single request.

  `inc=artist-credits+releases+release-groups+isrcs+work-rels`, which is what
  makes enrichment affordable: verified live, one lookup returns the ISRCs, the
  length, the artist credit, the releases — with each release's own title,
  barcode, id and **release group** — and the work relations a classical
  recording performs.

  The release group is what artwork comes from, and it costs nothing extra here:
  see `OnePlaylist.CoverArt.Client` for why a cover belongs to the album rather
  than to whichever pressing won the barcode. Nothing in this response says
  whether a cover exists — that is the archive's own question to answer.

  `{:ok, nil}` is MusicBrainz answering 404 — an identifier it does not hold.
  That is an answer rather than a failure, and the caller records it as one.
  """
  @spec recording(String.t(), keyword()) :: {:ok, map() | nil} | {:error, Exception.t()}
  def recording(mbid, opts \\ []) when is_binary(mbid) do
    Service.call(fn ->
      [
        base_url: @base_url,
        url: "/recording/#{mbid}",
        params: [fmt: "json", inc: "artist-credits+releases+release-groups+isrcs+work-rels"],
        headers: [{"user-agent", user_agent()}],
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(Application.get_env(:one_playlist, :musicbrainz_req_options, []))
      |> Req.new()
      |> Req.get()
      |> handle_lookup(mbid)
    end)
  end

  defp handle_lookup({:ok, %{status: 503}}, _mbid), do: :retry
  defp handle_lookup({:ok, %{status: 404}}, _mbid), do: {:ok, nil}
  defp handle_lookup({:ok, %{status: 200, body: body}}, _mbid), do: {:ok, body}

  defp handle_lookup({:ok, %{status: status}}, mbid) do
    Logger.warning("musicbrainz recording lookup returned #{status} for #{mbid}")
    {:error, %RuntimeError{message: "musicbrainz returned #{status}"}}
  end

  defp handle_lookup({:error, _reason}, _mbid), do: :retry

  # A MusicBrainz recording as a candidate the matching ladder can score. The
  # album comes from the first release it names, which is what the ladder
  # compares against a stored recording's own album.
  defp to_track(recording) do
    release = recording |> Map.get("releases", []) |> List.first() || %{}

    %Track{
      provider: :musicbrainz,
      provider_id: recording["id"],
      title: recording["title"],
      artists: recording |> Map.get("artist-credit", []) |> Enum.map(& &1["name"]),
      album: release["title"],
      album_upc: release["barcode"],
      # MusicBrainz reports length in milliseconds; everything here is seconds.
      duration_seconds: recording["length"] && div(recording["length"], 1000),
      isrc: recording |> Map.get("isrcs", []) |> List.first()
    }
  end

  # Lucene syntax, so a quote or a backslash in a title would otherwise change
  # the query rather than be searched for.
  defp escape(text), do: String.replace(text, ~r/(["\\])/, "\\\\\\1")

  # 503 is how MusicBrainz says "slow down", so it is the one status worth
  # retrying. `ExternalService` sees `:retry` and applies the backoff.
  defp handle_works({:ok, %{status: 503}}), do: :retry

  defp handle_works({:ok, %{status: 200, body: body}}) do
    titles =
      body
      |> Map.get("works", [])
      |> Enum.filter(&((&1["score"] || 0) >= @score_floor))
      |> Enum.map(& &1["title"])
      |> Enum.reject(&is_nil/1)

    {:ok, titles}
  end

  defp handle_works({:ok, %{status: status}}) do
    Logger.warning("musicbrainz work search returned #{status}")
    {:error, %RuntimeError{message: "musicbrainz returned #{status}"}}
  end

  defp handle_works({:error, _reason}), do: :retry

  defp handle({:ok, %{status: 503}}, _isrc), do: :retry

  defp handle({:ok, %{status: 404}}, _isrc), do: {:ok, nil}

  defp handle({:ok, %{status: 200, body: body}}, isrc), do: {:ok, family(body, isrc)}

  defp handle({:ok, %{status: status}}, isrc) do
    Logger.warning("musicbrainz returned #{status} for #{isrc}")
    {:error, %RuntimeError{message: "musicbrainz returned #{status}"}}
  end

  # A transport failure — DNS, a reset connection, a timeout. Retryable in the
  # ordinary way, and the reason is not inspected because nothing here would do
  # anything different with it.
  defp handle({:error, _reason}, _isrc), do: :retry

  # Several recordings can carry one ISRC — a single and an album track that
  # were registered separately, usually. Their families are unioned rather than
  # the first one taken: the question is "what else is this recording called",
  # and picking arbitrarily among equally valid answers would make the result
  # depend on MusicBrainz's ordering.
  defp family(%{"recordings" => [_ | _] = recordings}, isrc) do
    isrcs =
      recordings
      |> Enum.flat_map(&(&1["isrcs"] || []))
      |> Enum.map(&Isrc.normalize/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.concat([isrc])
      |> Enum.uniq()
      |> Enum.sort()

    %{recording_mbid: recordings |> List.first() |> Map.get("id"), isrcs: isrcs}
  end

  defp family(_body, _isrc), do: nil

  defp user_agent do
    :one_playlist
    |> Application.get_env(OnePlaylist.MusicBrainz, [])
    |> Keyword.get(:user_agent, @default_user_agent)
  end
end
