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
