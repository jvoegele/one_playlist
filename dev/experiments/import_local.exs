# Imports a playlist file from disk, without a browser session.
#
#     echo /path/to.csv > dev/experiments/PLAYLIST
#     bin/remote dev/experiments/import_local.exs
#
# The path comes through a **file**, not an environment variable. `bin/remote`
# evaluates this on the server node, so `System.get_env/1` reads that node's
# environment and a variable set beside the command never arrives. The
# filesystem is what the two share. (Documented in the header of `bin/remote`,
# and walked into twice anyway.)
#
# `Imports.import/4` stores the uploaded file in Supabase Storage as the user,
# which needs a GoTrue session a script does not have. Everything *after* that
# is the same: parse, create the transfer, write the parsed source, queue the
# job. This does exactly that and skips the upload, so the transfer has no file
# to re-read — a re-run works from the stored `transfer_sources` row, which is
# what the worker uses anyway.
#
# For experiments and measurement. The real path is the upload form.
alias OnePlaylist.Formats
alias OnePlaylist.Providers.Connection
alias OnePlaylist.Transfers.{Source, Transfer, TransferWorker}
alias OnePlaylist.{Matching, Repo}

import Ecto.Query

path = "dev/experiments/PLAYLIST" |> File.read!() |> String.trim()
content = File.read!(path)
filename = Path.basename(path)

owner =
  Repo.one!(
    from c in Connection,
      where: c.provider == :tidal and c.status == :active,
      select: c.user_id,
      limit: 1
  )

{:ok, format} = Formats.for_filename(filename)
{:ok, tracks} = Formats.parse(format, content)

attrs = %{
  user_id: owner,
  source_provider: :file,
  # No storage object, so this names the file it came from rather than a path.
  # A re-run reads `transfer_sources`, not this.
  source_playlist_id: "local:#{filename}",
  source_playlist_name: filename,
  destination_provider: :tidal,
  destination_playlist_name: Path.rootname(filename)
}

{:ok, %{transfer: transfer}} =
  Ecto.Multi.new()
  |> Ecto.Multi.insert(
    :transfer,
    Transfer.create_changeset(%Transfer{}, Map.put(attrs, :threshold, Matching.threshold()))
  )
  |> Ecto.Multi.insert(:source, fn %{transfer: t} ->
    Source.changeset(t.id, owner, tracks, format)
  end)
  |> Ecto.Multi.run(:job, fn _repo, %{transfer: t} ->
    %{transfer_id: t.id} |> TransferWorker.new() |> Oban.insert()
  end)
  |> Repo.transaction()

%{transfer_id: transfer.id, tracks: length(tracks), queued: true}
