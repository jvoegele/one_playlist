# `remove_tracks/4` against both live services, through the adapter rather than
# the client — so what is exercised is what a caller would actually reach for.
#
# Each half builds a scratch playlist holding one track twice, removes that
# track, checks both copies went and the other survived, then removes again to
# show a second call is harmless. Cleans up after itself.
alias OnePlaylist.Music.Track
alias OnePlaylist.Providers

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

user_id =
  OnePlaylist.Repo.query!(
    "select user_id::text from public.provider_connections where provider='tidal'"
  )
  |> Map.fetch!(:rows)
  |> List.first()
  |> List.first()

exercise = fn provider, adapter, sample ->
  try do
    {:ok, connection} = Providers.fetch_usable_connection(user_id, provider)
    {:ok, playlist} = adapter.create_playlist(connection, "one_playlist removal check", [])
    id = playlist.provider_id

    [a, b] = sample.(connection)

    # `a` twice: the duplicate is what `meta.itemId` and `songIndexToRemove`
    # both exist to disambiguate.
    {:ok, _added} = adapter.add_tracks(connection, id, [a, b, a], [])
    {:ok, before} = adapter.playlist_track_ids(connection, id, [])

    {:ok, removed} = adapter.remove_tracks(connection, id, [a], [])
    {:ok, remaining} = adapter.playlist_track_ids(connection, id, [])

    # Again, on a playlist that no longer holds it.
    {:ok, removed_again} = adapter.remove_tracks(connection, id, [a], [])
    {:ok, after_second} = adapter.playlist_track_ids(connection, id, [])

    :ok = adapter.remove_tracks(connection, id, [b], []) |> elem(0)

    _ =
      case provider do
        :tidal -> OnePlaylist.Providers.Tidal.Client.delete_playlist(connection.access_token, id)
        :navidrome -> OnePlaylist.Providers.Subsonic.Client.delete_playlist(connection, id)
      end

    %{
      before: before,
      removed: removed,
      remaining: remaining,
      removed_again: removed_again,
      after_second: after_second,
      verdict:
        cond do
          before != [a.provider_id, b.provider_id, a.provider_id] -> "setup did not take"
          removed != 2 -> "expected both copies of a to go, got #{removed}"
          remaining != [b.provider_id] -> "expected only b to remain"
          removed_again != 0 -> "second removal should be a no-op, removed #{removed_again}"
          after_second != [b.provider_id] -> "second removal changed the playlist"
          true -> "OK — both copies removed, b untouched, second call a no-op"
        end
    }
  rescue
    e -> %{error: e.__struct__, message: Exception.message(e)}
  end
end

tidal_sample = fn connection ->
  {:ok, doc} =
    OnePlaylist.Providers.Tidal.Client.list_playlist_items(
      connection.access_token,
      "942d3318-590a-4e80-b271-696a68a630e7",
      country: connection.country
    )

  doc
  |> Map.get("data", [])
  |> Enum.take(2)
  |> Enum.map(&%Track{provider: :tidal, provider_id: &1["id"]})
end

navidrome_sample = fn connection ->
  {:ok, found} = OnePlaylist.Providers.Subsonic.Client.search(connection, "", limit: 2)
  Enum.map(found, &%Track{provider: :navidrome, provider_id: &1.provider_id})
end

%{
  tidal: exercise.(:tidal, OnePlaylist.Providers.Tidal, tidal_sample),
  navidrome: exercise.(:navidrome, OnePlaylist.Providers.Navidrome, navidrome_sample)
}
