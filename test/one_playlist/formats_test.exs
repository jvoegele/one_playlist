defmodule OnePlaylist.FormatsTest do
  @moduledoc "The registry: which formats exist, and what each is good for."

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Formats

  doctest OnePlaylist.Formats

  describe "for_filename/1" do
    test "matches on the extension, ignoring case" do
      assert Formats.for_filename("Road Trip.csv") == {:ok, :csv}
      assert Formats.for_filename("EXPORT.CSV") == {:ok, :csv}
      assert Formats.for_filename("/tmp/a.b/c.csv") == {:ok, :csv}
    end

    test "refuses what it does not know, rather than guessing from content" do
      # Sniffing would let a `.csv` that is really an M3U import as one long
      # unmatched title — worse than being told the extension is wrong.
      assert Formats.for_filename("mix.m3u") == {:error, :unknown_format}
      assert Formats.for_filename("no-extension") == {:error, :unknown_format}
    end
  end

  describe "parse/3 and render/3 disagree about unknown formats, deliberately" do
    test "parse reports it, because the format came from a user's filename" do
      assert {:error, error} = Formats.parse(:m3u, "anything")
      assert error.reason == :unknown_format
    end

    test "render refuses it, because the format came from us" do
      # The filter rule: an unknown format on the way out is this application's
      # bug, and an error tuple would let it travel.
      assert_precondition_violation(Formats.render(:m3u, []), label: :format_is_known)
    end
  end
end
