defmodule OnePlaylist.MusicBrainz.Client do
  @moduledoc """
  The one MusicBrainz call this application makes.

  `GET /ws/2/isrc/{isrc}?inc=isrcs` answers with every recording that ISRC names
  and, because of `inc=isrcs`, every *other* ISRC each of those recordings is
  known by. One request, which is the whole reason this is affordable at one
  request per second.

      /ws/2/isrc/USJY50700001?fmt=json&inc=isrcs
      → recording ea8c7b4c…  "Setting Forth"
        isrcs: ["USJY50700001", "USJY51700100"]

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

  # 503 is how MusicBrainz says "slow down", so it is the one status worth
  # retrying. `ExternalService` sees `:retry` and applies the backoff.
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
