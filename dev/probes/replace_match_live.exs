# `Transfers.override/4` replacing an already-matched row, against live TIDAL.
#
# What the unit tests cannot reach: whether removing the superseded track works
# immediately after adding its replacement, on a playlist the provider has just
# been written to. Builds its own scratch playlist and transfer, and removes
# both afterwards — it never touches a real transfer.
alias OnePlaylist.Accounts.Session
alias OnePlaylist.Providers
alias OnePlaylist.Providers.Tidal
alias OnePlaylist.Repo
alias OnePlaylist.Transfers
alias OnePlaylist.Transfers.Transfer
alias OnePlaylist.Transfers.TransferItem

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

user_id =
  Repo.query!("select user_id::text from public.provider_connections where provider='tidal'")
  |> Map.fetch!(:rows)
  |> List.first()
  |> List.first()

session = %Session{
  user_id: user_id,
  email: "probe@example.test",
  access_token: "not-used-on-this-path",
  refresh_token: "not-used-on-this-path",
  expires_at: DateTime.add(DateTime.utc_now(), 3600)
}

try do
  {:ok, connection} = Providers.fetch_usable_connection(user_id, :tidal)

  {:ok, doc} =
    Tidal.Client.list_playlist_items(
      connection.access_token,
      "942d3318-590a-4e80-b271-696a68a630e7",
      country: connection.country
    )

  [wrong, right] = doc |> Map.get("data", []) |> Enum.take(2) |> Enum.map(& &1["id"])

  # Any scratch playlist a previous failed run left behind.
  {:ok, existing} = Tidal.stream_playlists(connection, [])

  for stale <- Enum.filter(existing, &(&1.name == "one_playlist replace check")) do
    Tidal.Client.delete_playlist(connection.access_token, stale.provider_id)
  end

  {:ok, playlist} = Tidal.create_playlist(connection, "one_playlist replace check", [])
  {:ok, 1} = Tidal.add_tracks(connection, playlist.provider_id, [%{provider_id: wrong}])

  {:ok, transfer} =
    Transfers.create(%{
      user_id: user_id,
      source_provider: :tidal,
      source_playlist_id: "probe-src",
      source_playlist_name: "replace check",
      destination_provider: :tidal,
      threshold: 0.75
    })

  # The job this queued would run the real pipeline against a source that does
  # not exist. Removed rather than cancelled, by raw SQL so the probe needs no
  # Ecto.Query macros.
  Repo.query!("delete from oban.oban_jobs where args->>'transfer_id' = $1", [transfer.id])

  {:ok, transfer} =
    Transfers.record_progress(transfer, %{
      status: :completed,
      destination_playlist_id: playlist.provider_id,
      total_tracks: 1,
      matched_count: 1,
      added_count: 1,
      unmatched_count: 0
    })

  Repo.insert!(%TransferItem{
    transfer_id: transfer.id,
    user_id: user_id,
    position: 0,
    source_track_id: "probe-s0",
    source_title: "Whatever",
    outcome: :matched,
    destination_track_id: wrong,
    strategy: "text",
    confidence: "high",
    candidates: [%{"provider_id" => right, "title" => "The right one", "artist" => "Somebody"}],
    inserted_at: DateTime.utc_now()
  })

  before = Tidal.playlist_track_ids(connection, playlist.provider_id) |> elem(1)

  outcome =
    Transfers.override(session, transfer, 0, %{
      "provider_id" => right,
      "title" => "The right one",
      "artist" => "Somebody"
    })

  {status, corrected} =
    case outcome do
      {:ok, t} -> {:replaced, t}
      {:ok, t, :not_removed} -> {:added_but_not_removed, t}
      {:error, reason} -> {{:error, inspect(reason)}, nil}
    end

  after_ids = Tidal.playlist_track_ids(connection, playlist.provider_id) |> elem(1)

  _ = Tidal.Client.delete_playlist(connection.access_token, playlist.provider_id)
  _ = Repo.delete(transfer)

  %{
    wrong: wrong,
    right: right,
    before: before,
    after: after_ids,
    status: status,
    counters:
      corrected &&
        {corrected.matched_count, corrected.added_count, corrected.unmatched_count},
    verdict:
      cond do
        status != :replaced -> "override did not complete cleanly: #{inspect(status)}"
        after_ids != [right] -> "expected only the right track, got #{inspect(after_ids)}"
        true -> "OK — wrong track out, right track in, on a live playlist"
      end
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
