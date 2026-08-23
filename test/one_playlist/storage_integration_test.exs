defmodule OnePlaylist.StorageIntegrationTest do
  @moduledoc """
  The storage policies, against a real Supabase.

  These exist because `storage.objects` grants `authenticated` **every**
  privilege — Supabase granted them, not us — so the four policies in
  `20260823120000_create_playlists_bucket.exs` are the only thing between one
  user's uploads and another's. A test that only checked our own code would
  prove nothing about that.

  Excluded by default. Run with the command in
  `test/one_playlist/accounts_test.exs`, which sets the same two variables.
  """

  use ExUnit.Case, async: false

  alias OnePlaylist.Accounts
  alias OnePlaylist.Storage

  @moduletag :supabase

  setup do
    unless OnePlaylist.Supabase.configured?(), do: flunk("Supabase is not configured")

    password = "a-perfectly-fine-password"
    {:ok, alice} = Accounts.sign_up(unique_email(), password)
    {:ok, bob} = Accounts.sign_up(unique_email(), password)

    {:ok, path} = Storage.put(alice, :imports, "road-trip.csv", "title,artists\nA,B\n")

    %{alice: alice, bob: bob, path: path}
  end

  defp unique_email do
    "storage-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}@one-playlist.test"
  end

  describe "a user's own files" do
    test "round-trip through Storage", %{alice: alice, path: path} do
      assert {:ok, "title,artists\nA,B\n"} = Storage.get(alice, path)
    end

    test "are stored under the owner's id", %{alice: alice, path: path} do
      assert String.starts_with?(path, alice.user_id <> "/imports/")
    end

    test "can be deleted by their owner", %{alice: alice, path: path} do
      assert :ok = Storage.delete(alice, path)
      assert {:error, %{reason: :not_found}} = Storage.get(alice, path)
    end

    test "can be handed to a browser as a signed URL", %{alice: alice, path: path} do
      # The bucket is private, so this is the only way to give a browser the file
      # without proxying every byte through Phoenix.
      assert {:ok, url} = Storage.signed_url(alice, path, 60)
      assert url =~ "token="
      assert url =~ "playlists"
    end
  end

  describe "another user's files" do
    test "cannot be read, even by exact path", %{bob: bob, path: path} do
      # Bob knows the path — this test hands it to him. The select policy is
      # what stops him, not obscurity.
      assert {:error, error} = Storage.get(bob, path)
      assert error.reason == :not_found
    end

    test "cannot be deleted, and survive the attempt", %{alice: alice, bob: bob, path: path} do
      # The delete policy's `using` clause filters the row out, so Storage
      # reports a successful deletion of nothing. `Storage.delete/2` converts
      # that silence into `:not_found`, because a caller who believes it deleted
      # a file will not try again.
      assert {:error, %{reason: :not_found}} = Storage.delete(bob, path)
      assert {:ok, _still_there} = Storage.get(alice, path)
    end

    test "cannot be written into", %{alice: alice, bob: bob} do
      # A forged session, because the API cannot produce this: `put/4` builds the
      # path from the session's own user id. So this tests the *policy*, which
      # is the only thing that would stop a `path_for/3` bug from filing one
      # user's uploads in another's folder.
      forged = %{bob | user_id: alice.user_id}

      assert {:error, error} = Storage.put(forged, :imports, "planted.csv", "x")

      assert error.reason == :forbidden,
             "a refused write is loud: a user cannot cause one, so it means our path was wrong"
    end
  end

  describe "a file that does not exist" do
    test "is indistinguishable from one belonging to somebody else", %{bob: bob, path: path} do
      # Answering differently would confirm that a path names a real object.
      theirs = Storage.get(bob, path)
      imaginary = Storage.get(bob, Storage.path_for(bob.user_id, :imports, "no-such-file.csv"))

      assert theirs |> elem(1) |> Map.get(:reason) == imaginary |> elem(1) |> Map.get(:reason)
    end
  end
end
