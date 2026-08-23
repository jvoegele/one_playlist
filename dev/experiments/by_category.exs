# The hard playlist's outcome, read by failure mode rather than as one number.
import Ecto.Query
alias OnePlaylist.Transfers
alias OnePlaylist.Transfers.TransferItem

id = "dev/experiments/TRANSFER" |> File.read!() |> String.trim()
{:ok, t} = Transfers.fetch_unscoped(id)

categories =
  "dev/experiments/hard_playlist_categories.json"
  |> File.read!()
  |> Jason.decode!()
  |> Enum.with_index()
  |> Map.new(fn {row, i} -> {i, row["category"]} end)

rows =
  OnePlaylist.Repo.all(
    from i in TransferItem,
      where: i.transfer_id == ^id,
      order_by: i.position,
      select: {i.position, i.outcome, i.strategy, i.confidence, i.reason, i.source_title,
               i.source_artist, i.destination_title, i.destination_artist}
  )

grade = fn
  {_, :unmatched, _, _, _, _, _, _, _} -> :unmatched
  {_, _, _, c, _, _, _, _, _} when c in ["exact_isrc", "linked_isrc", "exact_upc"] -> :identifier
  {_, _, _, "high", _, _, _, _, _} -> :text_high
  _ -> :text_weak
end

by_category =
  rows
  |> Enum.group_by(fn {p, _, _, _, _, _, _, _, _} -> categories[p] end)
  |> Map.new(fn {cat, rs} -> {cat, rs |> Enum.frequencies_by(grade) |> Enum.sort()} end)

%{
  status: t.status,
  counts: Map.take(t, [:total_tracks, :matched_count, :added_count, :unmatched_count]),
  by_category: by_category,
  weak_or_unmatched:
    for {p, o, s, c, reason, title, artist, dest, dest_artist} <- rows,
        o == :unmatched or c in ["medium", "low"] do
      "#{categories[p]} | #{artist} — #{title} | " <>
        if(o == :unmatched, do: "UNMATCHED (#{reason})", else: "→ #{dest_artist} — #{dest} (#{s}/#{c})")
    end
}
