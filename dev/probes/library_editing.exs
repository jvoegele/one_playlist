# The editing operations against the dev database, on a playlist built from a
# real TIDAL transfer rather than fixtures.
#
# Read-mostly: it makes its own playlist, edits that, and deletes it. Nothing
# existing is touched.
alias OnePlaylist.Library
alias OnePlaylist.Providers
alias OnePlaylist.Providers.Tidal
alias OnePlaylist.Repo

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

user_id =
  Repo.query!("select user_id::text from public.provider_connections where provider='tidal'")
  |> Map.fetch!(:rows)
  |> List.first()
  |> List.first()

try do
  {:ok, _library} = Providers.ensure_library(user_id)
  {:ok, tidal} = Providers.fetch_usable_connection(user_id, :tidal)

  # Four real tracks, so the ordering assertions are about recognisable titles.
  {:ok, doc} =
    Tidal.Client.list_playlist_items(
      tidal.access_token,
      "942d3318-590a-4e80-b271-696a68a630e7",
      country: tidal.country
    )

  tracks =
    doc
    |> Map.get("included", [])
    |> Enum.filter(&(&1["type"] == "tracks"))
    |> Enum.take(4)
    |> Enum.map(fn resource -> Tidal.Mapper.track(resource, Tidal.Mapper.index_included(doc)) end)

  {:ok, playlist} = Library.create_playlist(user_id, "editing probe")
  4 = Library.append(user_id, playlist.id, tracks)

  titles = fn -> Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) end

  before = titles.()

  # Move the last one to the top, one place at a time.
  [_a, _b, _c, last] = Library.entries(user_id, playlist.id)

  for _step <- 1..3 do
    Library.move_entry(user_id, playlist.id, last.id, :up)
  end

  after_moves = titles.()

  # Remove the one now in the middle.
  [_first, second | _rest] = Library.entries(user_id, playlist.id)
  :ok = Library.remove_entry(user_id, playlist.id, second.id)

  after_remove = titles.()

  {:ok, renamed} = Library.update_playlist(user_id, playlist.id, %{name: "editing probe (renamed)"})

  recordings_before = Repo.aggregate(Library.Recording, :count)
  :ok = Library.delete_playlist(user_id, playlist.id)
  recordings_after = Repo.aggregate(Library.Recording, :count)

  %{
    before: before,
    after_moves: after_moves,
    after_remove: after_remove,
    renamed_to: renamed.name,
    recordings_kept: recordings_before == recordings_after,
    gone: Library.fetch_playlist(user_id, playlist.id) == :error,
    verdict:
      cond do
        after_moves != [List.last(before) | Enum.take(before, 3)] ->
          "three moves up should put the last entry first"

        length(after_remove) != 3 ->
          "removing one entry should leave three"

        Enum.at(after_moves, 1) in after_remove ->
          "the removed entry is still there"

        not (recordings_before == recordings_after) ->
          "deleting a playlist deleted recordings, which belong to nobody"

        true ->
          "OK — reordered, removed one, renamed, deleted, recordings untouched"
      end
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
