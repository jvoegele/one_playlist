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

  ## The URL is constructed, so existence has to be asked

  `coverartarchive.org/release-group/{mbid}/front-250` needs no lookup to build,
  which is exactly why it must be checked before it is stored — a constructed
  URL for a group nobody has uploaded a scan for is a broken image in every view
  that shows the track.

  So `front_url/2` asks for the group's JSON first and answers `{:ok, nil}` when
  there is nothing. The request redirects to archive.org, which is where
  MetaBrainz keeps the files; `Req` follows that by default.
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
    Service.call(fn ->
      [
        base_url: @base_url,
        url: "/release-group/#{release_group_mbid}",
        params: [fmt: "json"],
        headers: [{"user-agent", user_agent()}],
        receive_timeout: Keyword.get(opts, :receive_timeout, 15_000)
      ]
      |> Keyword.merge(Application.get_env(:one_playlist, :cover_art_req_options, []))
      |> Req.new()
      |> Req.get()
      |> handle(release_group_mbid)
    end)
  end

  defp handle({:ok, %{status: 200}}, release_group_mbid) do
    {:ok, "#{@base_url}/release-group/#{release_group_mbid}/#{@size}"}
  end

  # Not an error. The archive says 404 for an album nobody has uploaded a scan
  # for, which is most of the long tail.
  defp handle({:ok, %{status: 404}}, _release_group_mbid), do: {:ok, nil}

  defp handle({:ok, %{status: 503}}, _release_group_mbid), do: :retry

  defp handle({:ok, %{status: status}}, release_group_mbid) do
    Logger.warning("cover art archive returned #{status} for #{release_group_mbid}")
    {:error, %RuntimeError{message: "cover art archive returned #{status}"}}
  end

  defp handle({:error, _reason}, _release_group_mbid), do: :retry

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
