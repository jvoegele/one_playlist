# Summarises a finished transfer. Reads the id from `dev/experiments/TRANSFER`.
import Ecto.Query
alias OnePlaylist.Transfers
alias OnePlaylist.Transfers.TransferItem

id = "dev/experiments/TRANSFER" |> File.read!() |> String.trim()
{:ok, t} = Transfers.fetch_unscoped(id)

rows =
  OnePlaylist.Repo.all(
    from i in TransferItem,
      where: i.transfer_id == ^id,
      select: {i.position, i.outcome, i.strategy, i.confidence, i.reason, i.source_title,
               i.destination_title, i.destination_album}
  )

%{
  status: t.status,
  counts: Map.take(t, [:total_tracks, :matched_count, :added_count, :unmatched_count]),
  by_strategy: Enum.frequencies_by(rows, fn {_, _, s, _, _, _, _, _} -> s end),
  by_confidence: Enum.frequencies_by(rows, fn {_, _, _, c, _, _, _, _} -> c end),
  unmatched:
    for {p, :unmatched, _, _, reason, title, _, _} <- rows do
      "#{p} #{title} — #{reason}"
    end,
  weak:
    for {p, o, s, c, _, title, dest, album} <- rows,
        o != :unmatched and c in ["medium", "low"] do
      "#{p} #{title} → #{dest} [#{album}] (#{s}/#{c})"
    end
}
