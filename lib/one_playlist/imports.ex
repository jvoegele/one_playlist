defmodule OnePlaylist.Imports do
  @moduledoc """
  Turning an uploaded playlist file into a queued transfer.

  The mirror of `OnePlaylist.Exports`, and unlike it this *does* go through
  `OnePlaylist.Transfers.Runner`: matching sparse file metadata against a real
  catalogue is the whole job, and the report of what could not be matched is the
  part a user actually reads.

  ## Everything happens in the request, on purpose

  `import/4` parses the file, stores it, creates the transfer and writes the
  parsed tracks before returning. None of that is deferred, for two reasons that
  point the same way.

  A worker could not do it. `OnePlaylist.Storage` reaches Supabase as the
  signed-in user so the bucket policies apply, and a worker has no session to
  be — GoTrue refresh tokens live in the browser's cookie, not in this database.
  Reading the upload from a job would mean the service key, bypassing every
  storage policy at once.

  And it is better this way round regardless. A malformed file is reported while
  the person is still looking at the form, naming the row that is wrong, rather
  than failing a background job they have to go and find. The slow part — the
  provider calls, the matching — is what the job is for, and that still happens
  there.

  ## What ends up where

  | | |
  | --- | --- |
  | The uploaded bytes | Supabase Storage, at `transfers.source_playlist_id` |
  | The parsed tracks | `OnePlaylist.Transfers.Source` |
  | The queued run | an `Oban` job, in the same transaction as the transfer |

  The file is the record of what was uploaded; the source row is the working
  copy the worker runs from. Keeping both is what makes "re-run this import" and
  "show me what I uploaded" possible later.
  """

  use Bond
  use Errata

  alias Ecto.Multi
  alias OnePlaylist.Accounts.Session
  alias OnePlaylist.Formats
  alias OnePlaylist.Matching
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Repo
  alias OnePlaylist.Storage
  alias OnePlaylist.Transfers.Source
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferWorker

  @doc """
  Imports a playlist file and queues a transfer into `destination`.

  `filename` decides the format, by extension. Returns the queued transfer.

  Parse failures come back as `OnePlaylist.Formats.UnreadablePlaylist`, which
  carries the row that is wrong where there is one — that is the error a form
  should render, and the reason parsing happens here rather than in the job.
  """
  # No precondition on the file's content or its name. This faces a person's
  # upload, so a malformed file is the expected input rather than a caller's bug,
  # and Meyer's filter rule (*OOSC* §11.6) says it comes back as a value. The
  # session is a different matter: it is established by `UserAuth` before any
  # request reaches here, so a malformed one is this application's mistake.
  @pre user_is_identified: is_binary(session.user_id) and session.user_id != ""
  @spec import(Session.t(), String.t(), binary(), Connection.provider()) ::
          {:ok, Transfer.t()} | {:error, Errata.Error.t() | Ecto.Changeset.t()}
  def import(%Session{} = session, filename, content, destination)
      when is_binary(filename) and is_binary(content) do
    with {:ok, format} <- format_for(filename),
         {:ok, tracks} <- Formats.parse(format, content),
         {:ok, path} <- Storage.put(session, :imports, unique_name(filename), content) do
      queue(session, filename, path, tracks, format, destination)
    end
  end

  # The transfer, its parsed source and its job, or none of them. A transfer
  # without a source row would reach the worker and fail with `SourceMissing`;
  # a source row without a transfer would be unreachable rows accumulating.
  #
  # The uploaded file is deliberately *outside* this transaction, because it is
  # already stored by the time we get here and Storage has no rollback. An
  # orphaned object is the failure worth having: it costs a few kilobytes, and
  # the alternative is a transfer whose file is gone.
  defp queue(session, filename, path, tracks, format, destination) do
    attrs = %{
      user_id: session.user_id,
      source_provider: :file,
      # The storage path, which is what a file's "playlist id" is. Not decorative:
      # it is how the original is found again for a re-run.
      source_playlist_id: path,
      source_playlist_name: filename,
      destination_provider: destination,
      destination_playlist_name: playlist_name(filename)
    }

    changeset =
      Transfer.create_changeset(%Transfer{}, Map.put(attrs, :threshold, Matching.threshold()))

    Multi.new()
    |> Multi.insert(:transfer, changeset)
    |> Multi.insert(:source, fn %{transfer: transfer} ->
      Source.changeset(transfer.id, session.user_id, tracks, format)
    end)
    |> Multi.run(:job, fn _repo, %{transfer: transfer} ->
      %{transfer_id: transfer.id} |> TransferWorker.new() |> Oban.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: transfer}} -> {:ok, transfer}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp format_for(filename) do
    case Formats.for_filename(filename) do
      {:ok, format} ->
        {:ok, format}

      {:error, :unknown_format} ->
        {:error,
         Errata.create(Formats.UnreadablePlaylist,
           reason: :unknown_format,
           message:
             "we cannot read #{Path.extname(filename)} files — " <>
               "known formats are #{Enum.join(Formats.known(), ", ")}",
           context: %{filename: filename}
         )}
    end
  end

  # Two uploads of "playlist.csv" are two different files, and the second must
  # not overwrite the first: the earlier transfer still names the earlier path
  # for its re-run. A timestamp prefix keeps them apart and keeps the folder
  # readable, which a bare UUID would not.
  defp unique_name(filename) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)

    "#{stamp}-#{Path.basename(filename)}"
  end

  # What to call the playlist at the destination. The filename without its
  # extension is what the person named it, and is what they will look for.
  defp playlist_name(filename), do: Path.rootname(Path.basename(filename))
end
