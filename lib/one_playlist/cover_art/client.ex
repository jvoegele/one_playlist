defmodule OnePlaylist.CoverArt.Client do
  @moduledoc """
  Cover art for an album, asked of the Cover Art Archive.

  ## Why the *release group* and not the release

  A cover belongs to an album, and MusicBrainz models an album as a **release
  group**: the original pressing, the reissue, the Japanese edition and the
  remaster are separate releases of one group, and they carry one picture
  between them.

  Enrichment used to ask whether the release it had chosen for a recording's
  barcode had a front cover, and that was wrong in a way that is obvious once
  stated: whichever pressing wins the barcode has nothing to do with which
  pressing somebody uploaded a scan for. Measured on *Pearl Jam* (2006) — of six
  releases in that group, three have a cover and three do not, and the one
  chosen for its barcode was one of the three that do not. Nine of the library's
  albums showed no artwork for that reason while their cover sat in the archive.

  Asking the group instead is both correct and cheaper: one question per album
  rather than one per pressing, and the group id arrives free in the recording
  lookup that enrichment already makes.

  ## The URL is constructed, so existence has to be asked — with `HEAD`

  `coverartarchive.org/release-group/{mbid}/front-250` needs no lookup to build,
  which is exactly why it must be checked before it is stored: a constructed URL
  for a group nobody has scanned is a broken image in every view that shows the
  track.

  The check is a **`HEAD` on that exact URL with redirects not followed**, which
  answers the question and nothing else — `307` means a cover exists, `404` means
  it does not.

  The first version asked for the group's JSON index instead, and measuring it
  is what produced this one:

  | | Cover exists | No cover |
  | --- | --- | --- |
  | `GET` the JSON index | **4091 ms** | 175 ms |
  | `HEAD`, not following | **144 ms** | 133 ms |

  Twenty-eight times slower, and the reason is the redirect chain: the archive
  hands off to `archive.org` and then to a specific storage node, so a check
  ends up fetching an index of every image in the group from a machine we have
  no relationship with. That hop is where the transport timeouts came from, and
  not following it removes them along with the latency.
  """

  alias OnePlaylist.CoverArt.Service

  require Logger

  @base_url "https://coverartarchive.org"

  # 250px because it is drawn at 40px in a report row and at list size elsewhere
  # — the same reasoning `OnePlaylist.Providers.Tidal.Mapper` applies when it
  # picks the smallest usable file rather than the largest.
  @size "front-250"

  @doc """
  The front cover for an album, or `nil` if the archive holds none.

  Never returns an error for a missing cover: `404` is the archive's ordinary
  answer for an album nobody has scanned, and it is an answer rather than a
  failure. A genuine fault — a timeout, a `5xx` — comes back as `{:error, _}` so
  the caller can tell "there is no cover" from "we could not find out", which
  matters because only the first should be remembered.
  """
  @spec front_url(String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, Exception.t()}
  def front_url(release_group_mbid, opts \\ [])

  def front_url(nil, _opts), do: {:ok, nil}

  def front_url(release_group_mbid, opts) when is_binary(release_group_mbid) do
    url = "#{@base_url}/release-group/#{release_group_mbid}/#{@size}"

    Service.call(fn ->
      [
        url: url,
        headers: [{"user-agent", user_agent()}],
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000),
        # The whole point. Following it would fetch the image itself from an
        # archive.org node — see the moduledoc's measurement.
        redirect: false,
        # `ExternalService` owns retrying; Req must not. Its default would add
        # three attempts of its own inside each guarded call, invisible to the
        # breaker and outside the rate limiter. See
        # `OnePlaylist.MusicBrainz.Client.isrc_family/2` for the full reasoning
        # and the incident that found it.
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:one_playlist, :cover_art_req_options, []))
      |> Req.new()
      |> Req.head()
      |> handle(url, release_group_mbid)
    end)
  end

  # A redirect *is* the answer: the archive points at the file it holds.
  defp handle({:ok, %{status: status}}, url, _mbid) when status in 300..399, do: {:ok, url}

  # Not an error. The archive says 404 for an album nobody has uploaded a scan
  # for, which is most of the long tail.
  defp handle({:ok, %{status: 404}}, _url, _mbid), do: {:ok, nil}

  defp handle({:ok, %{status: 503}}, _url, _mbid), do: :retry

  defp handle({:ok, %{status: status}}, _url, mbid) do
    Logger.warning("cover art archive returned #{status} for #{mbid}")
    {:error, %RuntimeError{message: "cover art archive returned #{status}"}}
  end

  defp handle({:error, _reason}, _url, _mbid), do: :retry

  # MetaBrainz asks for an application name and a way to get in touch, and
  # blocks clients that do not identify themselves. The same string
  # `OnePlaylist.MusicBrainz.Client` sends.
  defp user_agent do
    Application.get_env(
      :one_playlist,
      :musicbrainz_user_agent,
      "OnePlaylist/0.1 ( https://github.com/jvoegele/one_playlist )"
    )
  end
end
