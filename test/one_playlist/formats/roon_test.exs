defmodule OnePlaylist.Formats.RoonTest do
  @moduledoc """
  A real export from Roon, rather than one we wrote.

  `csv_test.exs` proves the codec handles the shapes we thought of, and its
  golden test proves we emit real RFC 4180. Neither can prove that what a
  *different program* emits is something we can read — and the first real file
  we were handed was separated by semicolons, which our parser could not read at
  all.

  The fixture is trimmed from a 58-track playlist to the nine rows that carry a
  distinct structural feature. Every one below is Roon's own output, unedited.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Formats.Csv
  alias OnePlaylist.Matching
  alias OnePlaylist.Matching.Strategy.Isrc

  @fixture Path.join(__DIR__, "../../fixtures/roon_export.csv")

  setup_all do
    {:ok, tracks} = @fixture |> File.read!() |> Csv.parse()
    %{tracks: tracks}
  end

  test "reads a semicolon-separated file", %{tracks: tracks} do
    # The finding that prompted all of this. Roon separates with `;`, which is
    # also what a spreadsheet saved as "CSV" produces in a European locale —
    # there, `,` is the decimal point. Read as comma-separated, the whole header
    # is one unrecognised column and the file is rejected outright.
    assert length(tracks) == 9
  end

  test "reads the singular `artist` header", %{tracks: tracks} do
    assert Enum.map(tracks, & &1.artists) |> Enum.uniq() == [["Pearl Jam"], ["Eddie Vedder"]]
  end

  test "keeps a comma inside a field", %{tracks: tracks} do
    # Unquoted in the file, and correct — a comma needs no escaping when the
    # separator is a semicolon. Reading it as comma-separated would split this
    # title in half.
    assert Enum.any?(tracks, &(&1.title == "Love, Reign O'er Me"))
  end

  test "keeps an empty trailing field as absent rather than blank", %{tracks: tracks} do
    without = Enum.find(tracks, &(&1.title == "Hard to Imagine"))

    assert without.isrc == nil
    assert Matching.searchable?(without), "still matchable by title"
  end

  test "the same title on two albums stays two tracks", %{tracks: tracks} do
    # `Better Man` appears twice in the real playlist, studio and live. Row
    # numbering is what keeps them distinct — `Track`'s `identifiable` invariant
    # exists because two id-less tracks compare equal and `Runner`'s
    # snapshot-and-diff would treat them as one.
    better = Enum.filter(tracks, &(&1.title == "Better Man"))

    assert length(better) == 2
    assert Enum.map(better, & &1.provider_id) |> Enum.uniq() |> length() == 2
    assert Enum.map(better, & &1.album) |> Enum.uniq() |> length() == 2
  end

  test "Roon writes ISRCs in lower case, and they are stored canonically", %{tracks: tracks} do
    # This used to assert the opposite — that the codec stored what the file
    # said, on the grounds that comparison normalises anyway. It does, and that
    # was not enough: `Tidal.candidates/3` sends the ISRC to the provider, and
    # TIDAL rejects a lower-case one outright. 57 of the 58 tracks in a real
    # import of this playlist failed, and the only one that matched was the one
    # row here with no ISRC at all.
    #
    # So the canonical form belongs to the value, not to one of its readers.
    raw = Enum.find(tracks, &(&1.title == "Rearviewmirror (Remastered)")).isrc

    assert raw == "USSM11100219", "normalised on the way in, not on the way out"
    assert Isrc.normalize(raw) == raw, "already canonical, so normalising again changes nothing"
  end

  test "version markers in titles survive for the matching engine to judge", %{tracks: tracks} do
    # Roon puts them in the title rather than a separate field, and the
    # distinction matters: `(Remastered)` and `(Album Version)` are editorial —
    # the same performance — while `(Live)` is a different recording and must
    # veto. `OnePlaylist.Matching.Normalize` classifies all three.
    titles = Enum.map(tracks, & &1.title)

    assert "Rearviewmirror (Remastered)" in titles
    assert "Down (Album Version)" in titles
    assert "Daughter (Live)" in titles
  end

  test "every row is usable by the matching engine", %{tracks: tracks} do
    # The codec's contract, against a real file rather than a generated one.
    assert Enum.all?(tracks, &Matching.searchable?/1)
  end
end
