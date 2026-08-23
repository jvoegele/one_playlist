defmodule OnePlaylist.Formats.CsvTest do
  @moduledoc """
  The CSV codec — what it accepts, what it refuses, and what it never guesses.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Formats.Csv
  alias OnePlaylist.Music.Track

  defp csv(rows), do: Enum.join(rows, "\n") <> "\n"

  describe "parse/2" do
    test "reads the columns we write" do
      {:ok, [track]} =
        Csv.parse(
          csv([
            "title,artists,album,isrc,duration_seconds,track_number,disc_number,version,album_upc,explicit",
            "Das Model,Kraftwerk,Die Mensch-Maschine,DEA116800088,218,3,1,,0724353897925,false"
          ])
        )

      assert track.title == "Das Model"
      assert track.artists == ["Kraftwerk"]
      assert track.album == "Die Mensch-Maschine"
      assert track.isrc == "DEA116800088"
      assert track.duration_seconds == 218
      assert track.track_number == 3
      assert track.volume_number == 1
      assert track.album_upc == "0724353897925"
      assert track.explicit == false
    end

    test "accepts what other people's exports call those columns" do
      # Nobody agrees on the title column's name, and a file that fails to
      # import because it says "Track Name" is a support burden, not a
      # correctness win.
      {:ok, [track]} =
        Csv.parse(csv(["Track Name,Artist Name,Album Name", "So What,Miles Davis,Kind of Blue"]))

      assert track.title == "So What"
      assert track.artists == ["Miles Davis"]
      assert track.album == "Kind of Blue"
    end

    test "ignores case, surrounding whitespace, and Excel's byte order mark" do
      # The BOM lands on the first header cell, so without stripping it `title`
      # would not match and the whole file would be rejected for having no title
      # column — from a file that plainly has one.
      with_bom = "﻿" <> csv([" TITLE , Artist ", "Neonlicht,Kraftwerk"])

      assert {:ok, [track]} = Csv.parse(with_bom)
      assert track.title == "Neonlicht"
      assert track.artists == ["Kraftwerk"]
    end

    test "reads a duration written as a clock" do
      # `3:45` is what a human-facing export writes; `225` is what we write.
      {:ok, tracks} =
        Csv.parse(
          csv([
            "title,duration",
            "a,225",
            "b,3:45",
            "c,1:02:03",
            "d,not a duration"
          ])
        )

      assert Enum.map(tracks, & &1.duration_seconds) == [225, 225, 3723, nil]
    end

    test "splits artists on the separator we write, and on nothing else" do
      # The restraint is the point. Splitting on `,`, `&` or `feat.` would turn
      # *Earth, Wind & Fire* into three artists and match none of them.
      {:ok, tracks} =
        Csv.parse(
          csv([
            "title,artists",
            "Shining Star,\"Earth, Wind & Fire\"",
            "The Boxer,Simon & Garfunkel",
            "Under Pressure,Queen; David Bowie"
          ])
        )

      assert Enum.map(tracks, & &1.artists) == [
               ["Earth, Wind & Fire"],
               ["Simon & Garfunkel"],
               ["Queen", "David Bowie"]
             ]
    end

    test "numbers each row so two identical tracks stay distinguishable" do
      # `Track`'s `identifiable` invariant exists because `to_string(nil)` is
      # `""`: two id-less tracks compare equal, and `Runner`'s snapshot-and-diff
      # would treat a genuine duplicate as one row.
      {:ok, tracks} = Csv.parse(csv(["title", "Alone Again Or", "Alone Again Or"]))

      assert Enum.map(tracks, & &1.provider_id) == ["1", "2"]
      assert Enum.all?(tracks, &(&1.provider == :file))
    end

    test "drops a row that could never be searched for, and keeps the rest" do
      # A row with neither a title nor an ISRC would raise
      # `Bond.PreconditionError` inside `search_tracks/3`, three layers from
      # here. Dropping it is what the codec's `every_track_is_usable`
      # postcondition promises.
      {:ok, tracks} = Csv.parse(csv(["title,artists", "Real Track,Someone", ",Just An Artist"]))

      assert Enum.map(tracks, & &1.title) == ["Real Track"]
    end

    test "keeps a row that has only an ISRC" do
      # Unsearchable by text, but rung 1 can still resolve it.
      {:ok, [track]} = Csv.parse(csv(["title,isrc", ",DEA116800088"]))

      assert track.isrc == "DEA116800088"
      assert track.title == nil
    end
  end

  describe "parse/2 refusing" do
    test "a file with no recognisable header" do
      # Deliberately not "assume it is artist,title". Guessing wrong imports the
      # entire playlist with the fields swapped, matches nothing, and looks like
      # the matching engine is broken.
      assert {:error, error} = Csv.parse(csv(["Kraftwerk,Das Model", "Kraftwerk,Neonlicht"]))
      assert error.reason == :no_header
      assert Errata.display_message(error) =~ "must name the columns"
    end

    test "a header with columns but no title and no ISRC" do
      assert {:error, error} = Csv.parse(csv(["album,duration", "Kind of Blue,225"]))
      assert error.reason == :no_title_column
    end

    test "an empty file" do
      assert {:error, error} = Csv.parse("")
      assert error.reason == :empty
    end

    test "a file whose every row is unusable" do
      # Importing zero tracks from a file that plainly has content is worse than
      # saying why.
      assert {:error, error} = Csv.parse(csv(["title,artists", ",Someone", ",Someone Else"]))
      assert error.reason == :nothing_usable
    end

    test "malformed CSV, without raising" do
      # An unterminated quote is what a truncated download looks like.
      assert {:error, error} = Csv.parse(csv(["title", "\"never closed"]))
      assert error.reason == :malformed
    end
  end

  describe "render/2" do
    test "writes the header even for no tracks" do
      # A header-only file re-parses as `:nothing_usable` rather than as
      # something mysterious, and opens in a spreadsheet as an empty playlist.
      rendered = IO.iodata_to_binary(Csv.render([]))

      assert rendered =~ "title,artists,album,isrc"
      assert {:error, %{reason: :nothing_usable}} = Csv.parse(rendered)
    end

    test "quotes a title containing the separator" do
      track = %Track{provider: :file, provider_id: "1", title: "Shining Star, Pt. 2"}

      assert IO.iodata_to_binary(Csv.render([track])) =~ ~s("Shining Star, Pt. 2")
    end

    test "produces exactly these bytes" do
      # A golden test, and it exists because of what the round-trip properties
      # *cannot* see. They compare `render` against `parse`, so any change made
      # to both at once — a different escape character, a different separator —
      # leaves them passing while the output stops being CSV that anything else
      # can read. Verified: switching the escape character breaks no property in
      # `csv_property_test.exs` and breaks this immediately.
      #
      # This is the only assertion in the format layer that faces outward.
      track = %Track{
        provider: :tidal,
        provider_id: "12345",
        title: "Das Model",
        artists: ["Kraftwerk", "Ralf Hütter"],
        album: "Die Mensch-Maschine",
        isrc: "DEA116800088",
        duration_seconds: 218,
        track_number: 3,
        volume_number: 1,
        album_upc: "0724353897925",
        explicit: false
      }

      assert IO.iodata_to_binary(Csv.render([track])) ==
               ~s(title,artists,album,isrc,duration_seconds,track_number,disc_number,version,album_upc,explicit\r\n) <>
                 ~s(Das Model,Kraftwerk; Ralf Hütter,Die Mensch-Maschine,DEA116800088,218,3,1,,0724353897925,false\r\n)
    end

    test "escapes the way RFC 4180 says, not merely reversibly" do
      # The other half of the golden test: a field containing a quote is escaped
      # by *doubling* it, which is what every spreadsheet expects. A scheme that
      # only satisfied our own parser could pick anything.
      track = %Track{provider: :file, provider_id: "1", title: ~s(He said "hi")}

      assert IO.iodata_to_binary(Csv.render([track])) =~ ~s("He said ""hi""")
    end

    test "survives a title containing quotes and newlines" do
      # Real catalogues contain both. Unquoted output would be wrong, not merely
      # risky — and the damage shows up on re-import, not on export.
      nasty = ~s(He said "hello"\nand left)
      track = %Track{provider: :file, provider_id: "1", title: nasty, artists: ["A"]}

      assert {:ok, [round_tripped]} = Csv.parse(IO.iodata_to_binary(Csv.render([track])))
      assert round_tripped.title == nasty
    end
  end

  describe "a spreadsheet" do
    test "is refused with the reason, not just the remedy" do
      # `PK\x03\x04` is a ZIP, which in this context is an .xlsx. Parsed as text
      # it fails as `:no_header` from a file that plainly has one.
      #
      # The message names the ISRC because that is the measured difference:
      # Roon's CSV export of a 58-track playlist carries an ISRC for 57 of them
      # and its spreadsheet export carries none.
      assert {:error, error} = Csv.parse(<<0x50, 0x4B, 0x03, 0x04, "anything else">>)
      assert error.reason == :looks_like_a_spreadsheet
      assert Errata.display_message(error) =~ "ISRC"
    end

    test "a file that merely starts with P and K is not one" do
      assert {:ok, [_track]} = Csv.parse(csv(["title", "PK Subban Appreciation Song"]))
    end
  end

  describe "the codec contract, inherited by every format" do
    # Proven with a deliberately broken implementation rather than by contriving
    # a call into the behaviour, because that is the only honest way to fail an
    # inherited contract: `Csv` cannot produce these values, which is precisely
    # what the contract is for.

    defmodule Unusable do
      @moduledoc false
      use Bond, behaviours: [OnePlaylist.Formats.Codec]

      alias OnePlaylist.Music.Track

      @impl true
      def kind, do: :metadata_based
      @impl true
      def extensions, do: ["bad"]
      @impl true
      def render(_tracks, _opts), do: []

      @impl true
      def parse(_content, _opts) do
        {:ok, [%Track{provider: :file, provider_id: "1", title: nil, isrc: nil}]}
      end
    end

    defmodule Unidentifiable do
      @moduledoc false
      use Bond, behaviours: [OnePlaylist.Formats.Codec]

      alias OnePlaylist.Music.Track

      @impl true
      def kind, do: :metadata_based
      @impl true
      def extensions, do: ["bad"]
      @impl true
      def render(_tracks, _opts), do: []

      @impl true
      def parse(_content, _opts) do
        {:ok, [%Track{provider: :file, provider_id: "", title: "Something"}]}
      end
    end

    test "a track nothing can search for is refused" do
      # The filter's debt to `search_tracks/3`, whose `searchable` precondition
      # raises. Without this the user would get a `Bond.PreconditionError` from
      # three layers away instead of "row 47 has no title".
      assert_postcondition_violation(Unusable.parse("", []), label: :every_track_is_usable)
    end

    test "a track with a blank id is refused" do
      # `to_string(nil)` is `""`, so id-less tracks compare equal and `Runner`'s
      # snapshot-and-diff conflates them — dropping a track or duplicating one.
      assert_postcondition_violation(Unidentifiable.parse("", []),
        label: :every_track_is_identifiable
      )
    end
  end
end
