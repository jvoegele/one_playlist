defmodule OnePlaylist.Exports do
  @moduledoc """
  Writing a provider's playlist out as a file.

  ## Why this is not a transfer

  `OnePlaylist.Transfers.Runner` reads a source, matches every track against a
  destination catalogue, snapshots what is already there, and writes the
  difference. An export does none of that: a file has no catalogue to search, so
  nothing can fail to match, there is nothing to be idempotent about, and the
  per-track report would say `matched` on every row by construction.

  Putting it through that pipeline would mean stubbing out most of what the
  pipeline is for. So exporting is a read, a render and a put, and it lives
  here — the asymmetry `OnePlaylist.Formats` describes, followed through to the
  code that uses it.

  Importing is the opposite case and *does* belong in the pipeline, because
  matching sparse file metadata against a real catalogue is the whole job.

  ## It runs in the request, not in a job

  Deliberately, and not only because it is quick. `OnePlaylist.Storage` acts as
  the signed-in user so that the storage policies apply, and a background worker
  has no session to act as: GoTrue refresh tokens live in the browser's cookie,
  not in the database, so an Oban job could only reach Storage with the service
  key and bypass every policy at once.

  A playlist of a few thousand tracks is a handful of provider requests and a
  few hundred kilobytes, so this is a reasonable thing to do while somebody
  waits. It would not be if exports grew a scheduler.
  """

  use Bond
  use Errata

  alias OnePlaylist.Accounts.Session
  alias OnePlaylist.Formats
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Storage

  @doc """
  Exports one of a user's playlists, returning where it was stored.

  Reads the playlist from `provider`, renders it as `format`, and stores it
  under the user's own folder. The caller turns the path into something a
  browser can fetch with `OnePlaylist.Storage.signed_url/3`.
  """
  # The session is the authority for *who* this is, not the `user_id` argument
  # that is not there: taking one would let a caller export somebody else's
  # playlist by passing their id, and `Storage` would happily file the result
  # under whoever was named. The provider connection and the storage path are
  # both derived from the same session, so they cannot disagree.
  #
  # The precondition sits on `opts`, because that is where the format arrives. A precondition can only
  # name parameters, and stating it against the derived value would mean
  # asserting nothing until the body had already run.
  @pre known_format: Keyword.get(opts, :format, :csv) in Formats.known()
  @spec export(Session.t(), Connection.provider(), String.t(), keyword()) ::
          {:ok, %{path: String.t(), filename: String.t(), track_count: non_neg_integer()}}
          | {:error, Errata.Error.t()}
  def export(%Session{} = session, provider, playlist_id, opts \\ []) do
    format = Keyword.get(opts, :format, :csv)
    name = Keyword.get(opts, :name, playlist_id)

    with {:ok, connection} <- Providers.fetch_usable_connection(session.user_id, provider),
         {:ok, adapter} <- Providers.adapter(provider),
         {:ok, tracks} <- read(adapter, connection, playlist_id),
         filename = filename_for(name, format),
         content = Formats.render(format, tracks),
         {:ok, path} <- Storage.put(session, :exports, filename, content) do
      {:ok, %{path: path, filename: filename, track_count: length(tracks)}}
    end
  end

  @doc """
  A filename a person will recognise in their downloads folder.

  The playlist's own name, with anything a filesystem or a `Content-Disposition`
  header would object to replaced. Not merely cosmetic: a name containing a
  slash would change the object's path, and the first segment of that path is
  what the storage policies compare `auth.uid()` against.

      iex> alias OnePlaylist.Exports
      iex> Exports.filename_for("Road Trip 2026", :csv)
      "Road Trip 2026.csv"
      iex> Exports.filename_for("Rock / Metal: the \\"best\\" of", :csv)
      "Rock _ Metal_ the _best_ of.csv"
  """
  # The postcondition is the security-relevant half. A filename that still
  # contained a `/` would add a path segment, and one that was entirely stripped
  # would produce a bare `.csv` under the user's folder — the first is a policy
  # bypass attempt, the second an unnameable file.
  @post has_the_extension: String.ends_with?(result, ".#{format}")
  @post is_a_single_segment: not String.contains?(result, "/")
  @post is_not_only_an_extension: String.length(result) > String.length(".#{format}")
  @spec filename_for(String.t(), Formats.format()) :: String.t()
  def filename_for(name, format) do
    cleaned =
      name
      |> to_string()
      |> String.replace(~r{[/\\:*?"<>|]}, "_")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, 120)

    base = if cleaned == "", do: "playlist", else: cleaned

    "#{base}.#{format}"
  end

  # `stream_tracks/3` answers a stream, and a stream that raises mid-iteration
  # would escape the `with` as an exception rather than an error tuple. The
  # provider adapters are guarded by `ExternalService`, so what escapes here is
  # already a classified failure; catching it keeps the return type honest.
  @spec read(module(), struct(), String.t()) :: {:ok, [Track.t()]} | {:error, Exception.t()}
  defp read(adapter, connection, playlist_id) do
    with {:ok, stream} <- adapter.stream_tracks(connection, playlist_id, []) do
      {:ok, Enum.to_list(stream)}
    end
  rescue
    error -> {:error, error}
  end
end
