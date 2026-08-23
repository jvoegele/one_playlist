defmodule OnePlaylist.RoundTripTest do
  @moduledoc """
  A playlist file leaving this application and coming back in.

  Everything else tests one half. `csv_property_test.exs` checks that render and
  parse agree with each other, which cannot see a change made to both;
  `storage_integration_test.exs` checks the bucket policies; the LiveView tests
  check the forms. This is the only test that walks the whole path a person
  actually takes, through real Supabase Storage and a real signed URL.

  It starts from Roon's own export rather than a generated playlist, so the lap
  is: somebody else's file, our tracks, our CSV, Storage, a browser download,
  and back in as an import.
  """

  use OnePlaylist.DataCase, async: false

  alias OnePlaylist.Accounts
  alias OnePlaylist.Formats
  alias OnePlaylist.Imports
  alias OnePlaylist.Storage
  alias OnePlaylist.Transfers.Source

  @moduletag :supabase

  @roon Path.join(__DIR__, "../fixtures/roon_export.csv")

  # What a file can carry. Provenance is not part of the deal: `provider_id` is
  # the row number, reassigned on every parse.
  defp portable(tracks) do
    Enum.map(tracks, &Map.take(&1, [:title, :artists, :album, :isrc, :duration_seconds]))
  end

  setup do
    unless OnePlaylist.Supabase.configured?(), do: flunk("Supabase is not configured")

    email = "roundtrip-#{System.system_time(:nanosecond)}@one-playlist.test"
    {:ok, session} = Accounts.sign_up(email, "a-perfectly-fine-password")

    %{session: session, original: File.read!(@roon)}
  end

  test "a playlist survives export, download and re-import", %{
    session: session,
    original: original
  } do
    {:ok, exported_tracks} = Formats.Csv.parse(original)

    csv = :csv |> Formats.render(exported_tracks) |> IO.iodata_to_binary()
    {:ok, path} = Storage.put(session, :exports, "Road Trip 2026.csv", csv)
    {:ok, url} = Storage.signed_url(session, path, download: "Road Trip 2026.csv")

    # Fetched the way a browser would, by following the signed URL.
    assert %{status: 200, body: downloaded} = Req.get!(url)

    {:ok, transfer} = Imports.import(session, "Road Trip 2026.csv", downloaded, :tidal)
    reimported = Repo.get(Source, transfer.id) |> Source.tracks()

    assert portable(reimported) == portable(exported_tracks)
    assert length(reimported) == 9
  end

  test "the stored key is sanitised while the download keeps its name", %{
    session: session,
    original: original
  } do
    # The two are different things and only one of them is a path. `path_for/3`
    # reduces the key to characters needing no URL encoding, because
    # supabase_storage does not encode the object path it builds
    # (storage-ex#37); the download name rides in a query parameter, where
    # encoding is not a problem.
    {:ok, tracks} = Formats.Csv.parse(original)
    csv = :csv |> Formats.render(tracks) |> IO.iodata_to_binary()

    {:ok, path} = Storage.put(session, :exports, "Road Trip 2026.csv", csv)
    {:ok, url} = Storage.signed_url(session, path, download: "Road Trip 2026.csv")

    assert Path.basename(path) == "Road-Trip-2026.csv"
    assert url =~ "Road%20Trip%202026.csv" or url =~ "Road+Trip+2026.csv"
  end

  test "another user cannot follow the signed URL's path", %{
    session: session,
    original: original
  } do
    # The URL itself is a bearer token by design, so this is about the *path*:
    # knowing where a file lives must not be enough to read it.
    {:ok, tracks} = Formats.Csv.parse(original)
    csv = :csv |> Formats.render(tracks) |> IO.iodata_to_binary()
    {:ok, path} = Storage.put(session, :exports, "Private.csv", csv)

    {:ok, stranger} =
      Accounts.sign_up(
        "stranger-#{System.system_time(:nanosecond)}@one-playlist.test",
        "a-perfectly-fine-password"
      )

    assert {:error, %{reason: :not_found}} = Storage.get(stranger, path)
    assert {:error, _} = Storage.signed_url(stranger, path, expires_in: 60)
  end
end
