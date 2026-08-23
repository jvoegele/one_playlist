defmodule OnePlaylist.StorageTest do
  @moduledoc """
  Path building, which is the ownership model and is pure.

  The parts that talk to Supabase are in `storage_integration_test.exs`, tagged
  `:supabase` — they need the stack running, for the same reason
  `accounts_test.exs` does.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Storage

  doctest OnePlaylist.Storage

  describe "path_for/3" do
    test "puts the owner first, because that is what the policy reads" do
      assert Storage.path_for("u-1", :imports, "a.csv") == "u-1/imports/a.csv"
      assert Storage.path_for("u-1", :exports, "a.csv") == "u-1/exports/a.csv"
    end

    test "reduces the name to characters that need no encoding" do
      # A space is the one that bites: `supabase_storage` does not encode the
      # object path it builds, so an unencoded space reaches Storage as a
      # malformed request. Verified against the API directly, where `%20` is
      # accepted. See docs/supabase-sdk-issues.md.
      assert Storage.path_for("u-1", :imports, "Pearl Jam.csv") == "u-1/imports/Pearl-Jam.csv"
      assert Storage.path_for("u-1", :imports, "a b  c.csv") == "u-1/imports/a-b-c.csv"
      assert Storage.path_for("u-1", :imports, "Café: 100%.csv") == "u-1/imports/Caf-100-.csv"
    end

    test "a name of nothing usable still addresses an object" do
      # An empty final segment is a path ending in `/`, which addresses the
      # folder rather than a file in it.
      assert Storage.path_for("u-1", :imports, "///") == "u-1/imports/file"
      assert Storage.path_for("u-1", :imports, "") == "u-1/imports/file"
    end

    test "refuses to build a path for nobody" do
      # A blank owner yields a path beginning `/imports/...`, whose first folder
      # is the empty string — matching no policy, so the object would be
      # unreadable by everyone including its owner, and would look like a
      # storage outage.
      assert_precondition_violation(Storage.path_for("", :imports, "a.csv"),
        label: :user_is_identified
      )
    end

    test "refuses a kind it does not know" do
      assert_precondition_violation(Storage.path_for("u-1", :something_else, "a.csv"),
        label: :known_kind
      )
    end
  end
end
