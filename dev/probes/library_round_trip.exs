# TIDAL → library → TIDAL, against the live account.
#
# What the stubs cannot show: that the library really is an ordinary transfer
# endpoint at both ends, that a track it has never seen is *stored* rather than
# reported missing, and that the recordings it stored are good enough to match
# back onto TIDAL afterwards. Cleans up both TIDAL playlists and its own rows.
alias OnePlaylist.Library
alias OnePlaylist.Providers
alias OnePlaylist.Providers.Tidal
alias OnePlaylist.Repo
alias OnePlaylist.Transfers
alias OnePlaylist.Transfers.Runner

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

user_id =
  Repo.query!("select user_id::text from public.provider_connections where provider='tidal'")
  |> Map.fetch!(:rows)
  |> List.first()
  |> List.first()

# A small real playlist to move. Bruce Springsteen - Favorites is 57 tracks;
# a slice of it keeps the probe inside TIDAL's write rate limit.
source_playlist = "942d3318-590a-4e80-b271-696a68a630e7"

run = fn attrs ->
  {:ok, transfer} = Transfers.create(attrs)

  Repo.query!("delete from oban.oban_jobs where args->>'transfer_id' = $1", [transfer.id])

  Runner.run(transfer)
end

try do
  {:ok, _library} = Providers.ensure_library(user_id)
  {:ok, tidal} = Providers.fetch_usable_connection(user_id, :tidal)

  # A three-track source, built as a real TIDAL playlist so the read path is the
  # ordinary one rather than a fixture.
  {:ok, doc} =
    Tidal.Client.list_playlist_items(tidal.access_token, source_playlist,
      country: tidal.country
    )

  ids = doc |> Map.get("data", []) |> Enum.take(3) |> Enum.map(& &1["id"])

  {:ok, source} = Tidal.create_playlist(tidal, "one_playlist library probe (source)", [])
  {:ok, 3} = Tidal.add_tracks(tidal, source.provider_id, Enum.map(ids, &%{provider_id: &1}))

  # 1. TIDAL → library. Nothing is held yet, so every track should be stored.
  {:ok, inbound} =
    run.(%{
      user_id: user_id,
      source_provider: :tidal,
      source_playlist_id: source.provider_id,
      source_playlist_name: "library probe",
      destination_provider: :library,
      destination_playlist_name: "From TIDAL",
      threshold: 0.75
    })

  inbound_rows = Transfers.items(inbound)
  held = Library.tracks(user_id, inbound.destination_playlist_id)

  # 2. library → TIDAL. The recordings should match back onto the catalogue.
  {:ok, outbound} =
    run.(%{
      user_id: user_id,
      source_provider: :library,
      source_playlist_id: inbound.destination_playlist_id,
      source_playlist_name: "From TIDAL",
      destination_provider: :tidal,
      destination_playlist_name: "one_playlist library probe (back)",
      threshold: 0.75
    })

  outbound_rows = Transfers.items(outbound)

  {:ok, returned} = Tidal.playlist_track_ids(tidal, outbound.destination_playlist_id)

  # 3. Re-run the inbound transfer: it should dedupe rather than double.
  {:ok, again} = Runner.run(inbound)

  # Read everything *before* cleaning up. Deleting a transfer cascades its
  # report rows, so a summary built afterwards reports an empty list and reads
  # like a failure.
  rerun_outcomes = again |> Transfers.items() |> Enum.map(&to_string(&1.outcome)) |> Enum.uniq()
  library_playlist = inbound.destination_playlist_id

  _ = Tidal.Client.delete_playlist(tidal.access_token, source.provider_id)
  _ = Tidal.Client.delete_playlist(tidal.access_token, outbound.destination_playlist_id)
  _ = Repo.delete(outbound)
  _ = Repo.delete(inbound)

  # The library playlist outlives the transfer that made it — which is the whole
  # point of the library — so the probe has to remove its own.
  _ =
    Repo.query!("delete from public.library_playlists where id = $1", [
      Ecto.UUID.dump!(library_playlist)
    ])

  %{
    inbound: %{
      counts: {inbound.matched_count, inbound.added_count, inbound.unmatched_count},
      strategies: Enum.map(inbound_rows, & &1.strategy),
      stored: Enum.map(held, & &1.title)
    },
    outbound: %{
      counts: {outbound.matched_count, outbound.added_count, outbound.unmatched_count},
      strategies: Enum.map(outbound_rows, & &1.strategy),
      returned_the_same_tracks: Enum.sort(returned) == Enum.sort(ids)
    },
    rerun: %{added: again.added_count, outcomes: rerun_outcomes},
    # Inbound is `stored` the first time these recordings are ever seen and
    # `isrc` afterwards — because the recording store is shared and outlives the
    # playlist that caused it, which is exactly the asset domain.md §5 claims
    # compounds. Both are correct; which one happened is worth reporting rather
    # than asserting.
    verdict:
      cond do
        inbound.unmatched_count > 0 ->
          "a destination that holds anything reported a miss"

        Enum.uniq(Enum.map(inbound_rows, & &1.strategy)) not in [["stored"], ["isrc"]] ->
          "inbound should be stored (first sighting) or isrc (already known)"

        Enum.sort(returned) != Enum.sort(ids) ->
          "the round trip lost or changed a track"

        again.added_count != 0 ->
          "the re-run doubled the library"

        true ->
          case Enum.uniq(Enum.map(inbound_rows, & &1.strategy)) do
            ["stored"] -> "OK — stored on the way in, matched back out, deduped on re-run"
            ["isrc"] -> "OK — recordings already held were reused, matched back out, deduped"
          end
      end
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
