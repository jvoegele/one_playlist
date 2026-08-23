defmodule OnePlaylist.ExportsTest do
  @moduledoc """
  Filename derivation, which is the part with a security edge.

  The provider read and the Storage put are exercised in
  `storage_integration_test.exs` and `navidrome_test.exs` respectively; what is
  worth testing here in isolation is the one function that turns a name a user
  chose into a path segment.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Exports

  doctest OnePlaylist.Exports

  describe "filename_for/2" do
    test "keeps a name a person will recognise" do
      assert Exports.filename_for("Road Trip 2026", :csv) == "Road Trip 2026.csv"
      assert Exports.filename_for("Café del Mar", :csv) == "Café del Mar.csv"
    end

    test "a slash cannot survive into the filename" do
      # This is the one that matters. Objects live at `<user_id>/<kind>/<name>`
      # and the storage policies compare `auth.uid()` against the first segment.
      # A name containing a slash adds a segment, which is a path a user chose
      # appearing inside a path that is the access control model.
      assert Exports.filename_for("Rock/Metal", :csv) == "Rock_Metal.csv"
      refute Exports.filename_for("../../etc/passwd", :csv) =~ "/"
    end

    test "a name of nothing but punctuation still yields a nameable file" do
      # Stripping everything would leave a bare `.csv`, which is a hidden file on
      # every Unix and unopenable on Windows.
      assert Exports.filename_for("///", :csv) == "___.csv"
      assert Exports.filename_for("   ", :csv) == "playlist.csv"
      assert Exports.filename_for("", :csv) == "playlist.csv"
    end

    test "a very long name is bounded" do
      name = String.duplicate("a", 400)

      assert String.length(Exports.filename_for(name, :csv)) <= 124
    end

    test "the characters a Content-Disposition header would object to are replaced" do
      assert Exports.filename_for(~s(a"b:c*d?e<f>g|h), :csv) == "a_b_c_d_e_f_g_h.csv"
    end
  end

  describe "export/4" do
    test "refuses a format nothing can write" do
      # A precondition rather than an error tuple: the format is chosen by this
      # application, not typed by a user, so an unknown one is our bug.
      session = %OnePlaylist.Accounts.Session{
        user_id: "u",
        access_token: "at",
        refresh_token: "rt",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      }

      assert_precondition_violation(
        Exports.export(session, :tidal, "p1", format: :m3u),
        label: :known_format
      )
    end
  end
end
