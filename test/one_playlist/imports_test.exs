defmodule OnePlaylist.ImportsTest do
  @moduledoc """
  Uploading a playlist file and getting a runnable transfer out of it.

  Tagged `:supabase` because `import/4` stores the uploaded file, and storing it
  is not incidental: it is what makes a re-run possible, and it is the step that
  has to happen in the request rather than the worker.
  """

  use OnePlaylist.DataCase, async: false

  alias OnePlaylist.Accounts
  alias OnePlaylist.Imports
  alias OnePlaylist.Matching
  alias OnePlaylist.Transfers.Source
  alias OnePlaylist.Transfers.Transfer

  @moduletag :supabase

  @roon Path.join(__DIR__, "../fixtures/roon_export.csv")

  setup do
    unless OnePlaylist.Supabase.configured?(), do: flunk("Supabase is not configured")

    email = "import-#{System.system_time(:nanosecond)}@one-playlist.test"
    {:ok, session} = Accounts.sign_up(email, "a-perfectly-fine-password")

    %{session: session, csv: File.read!(@roon)}
  end

  describe "import/4" do
    test "queues a transfer whose source is the parsed file", %{session: session, csv: csv} do
      assert {:ok, %Transfer{} = transfer} =
               Imports.import(session, "Pearl Jam.csv", csv, :tidal)

      assert transfer.source_provider == :file
      assert transfer.source_playlist_name == "Pearl Jam.csv"
      assert transfer.destination_provider == :tidal
      assert transfer.destination_playlist_name == "Pearl Jam"
      assert transfer.threshold == Matching.threshold()
    end

    test "the source playlist id is where the file was stored", %{session: session, csv: csv} do
      # Not decorative. It is how the original is found again, and its first
      # segment is what the storage policies compare `auth.uid()` against.
      {:ok, transfer} = Imports.import(session, "Pearl Jam.csv", csv, :tidal)

      assert String.starts_with?(transfer.source_playlist_id, session.user_id <> "/imports/")
      assert {:ok, ^csv} = OnePlaylist.Storage.get(session, transfer.source_playlist_id)
    end

    test "the worker can read the tracks without touching Storage", %{
      session: session,
      csv: csv
    } do
      # The point of the whole design. The parsed tracks are in the database, so
      # the job needs no session and no service key.
      {:ok, transfer} = Imports.import(session, "Pearl Jam.csv", csv, :tidal)

      source = Repo.get(Source, transfer.id)
      tracks = Source.tracks(source)

      assert source.track_count == 9
      assert length(tracks) == 9
      assert Enum.all?(tracks, &Matching.searchable?/1)
      assert Enum.map(tracks, & &1.provider) |> Enum.uniq() == [:file]
    end

    test "the tracks are the ones the file described", %{session: session, csv: csv} do
      {:ok, transfer} = Imports.import(session, "Pearl Jam.csv", csv, :tidal)

      tracks = Repo.get(Source, transfer.id) |> Source.tracks()
      first = hd(tracks)

      assert first.title == "Release (Brendan O'Brien Mix)"
      assert first.artists == ["Pearl Jam"]
      assert first.isrc == "ussm10805339"
    end

    test "a job is queued in the same transaction", %{session: session, csv: csv} do
      {:ok, transfer} = Imports.import(session, "Pearl Jam.csv", csv, :tidal)

      assert [job] =
               Repo.all(Ecto.Query.from(j in "oban_jobs", prefix: "oban", select: j.args))
               |> Enum.filter(&(&1["transfer_id"] == transfer.id))

      assert job["transfer_id"] == transfer.id
    end
  end

  describe "import/4 refusing" do
    test "a format we cannot read, naming what we can", %{session: session, csv: csv} do
      assert {:error, error} = Imports.import(session, "mix.m3u", csv, :tidal)
      assert error.reason == :unknown_format
      assert Errata.display_message(error) =~ "csv"
    end

    test "a malformed file, before anything is stored", %{session: session} do
      # The whole argument for parsing in the request: this is reported while the
      # person is looking at the form, and nothing was created.
      assert {:error, error} = Imports.import(session, "broken.csv", "no header here\n", :tidal)
      assert error.reason == :no_header

      # Scoped to this user, never a global count. `dev` and `test` share the
      # `postgres` database — see CLAUDE.md — so the table holds real rows that
      # a count would pick up, and the sandbox rolls back the test's own writes
      # rather than hiding everyone else's.
      assert Repo.aggregate(
               Ecto.Query.from(t in Transfer, where: t.user_id == ^session.user_id),
               :count
             ) == 0
    end

    test "a spreadsheet, with advice", %{session: session} do
      xlsx = <<0x50, 0x4B, 0x03, 0x04, "not really a spreadsheet">>

      assert {:error, error} = Imports.import(session, "playlist.csv", xlsx, :tidal)
      assert error.reason == :looks_like_a_spreadsheet
      assert Errata.display_message(error) =~ "ISRC"
    end
  end

  describe "two uploads of the same filename" do
    test "do not overwrite each other", %{session: session, csv: csv} do
      # The earlier transfer still names the earlier path for its re-run.
      {:ok, first} = Imports.import(session, "Playlist.csv", csv, :tidal)
      {:ok, second} = Imports.import(session, "Playlist.csv", csv, :tidal)

      assert first.source_playlist_id != second.source_playlist_id
      assert {:ok, _} = OnePlaylist.Storage.get(session, first.source_playlist_id)
      assert {:ok, _} = OnePlaylist.Storage.get(session, second.source_playlist_id)
    end
  end
end
