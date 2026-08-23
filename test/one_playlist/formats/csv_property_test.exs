defmodule OnePlaylist.Formats.CsvPropertyTest do
  @moduledoc """
  The round-trip laws, over generated playlists.

  These are the reason both ends of the format were built together. An importer
  alone can only be tested against files somebody wrote by hand, which proves the
  parser handles *the shapes you thought of*. Generating a playlist, writing it,
  reading it back and comparing tests the two halves against each other — and
  StreamData shrinks any disagreement to the smallest track that causes it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OnePlaylist.Formats.Csv
  alias OnePlaylist.Music.Track

  # Text that survives a round trip unchanged. Deliberately includes the
  # characters that break naive CSV — comma, quote, newline — because those are
  # the ones worth generating. Excludes the artist separator, which is not a
  # round-trip failure but a *documented* transformation: `"a;b"` in one artist
  # field is two artists on the way back, by design.
  defp text do
    gen all(
          raw <-
            string(
              Enum.concat([
                ?a..?z,
                ?A..?Z,
                ?0..?9,
                [?\s, ?,, ?", ?\n, ?', ?-, ?., ?&, ?/, ?ä, ?ø]
              ]),
              min_length: 1,
              max_length: 30
            ),
          trimmed = String.trim(raw),
          trimmed != ""
        ) do
      trimmed
    end
  end

  defp maybe(generator), do: one_of([constant(nil), generator])

  # A track in the form the codec can represent exactly. `provider` and
  # `provider_id` are omitted on purpose — a file does not know where a track
  # came from, and `parse/2` assigns the row number — so they are the fields the
  # round trip is *not* expected to preserve.
  defp portable_track do
    gen all(
          title <- text(),
          artists <- list_of(text(), max_length: 3),
          album <- maybe(text()),
          isrc <- maybe(string(?A..?Z, length: 12)),
          duration <- maybe(integer(0..7200)),
          track_number <- maybe(integer(1..99)),
          disc_number <- maybe(integer(1..9)),
          version <- maybe(text()),
          upc <- maybe(string(?0..?9, length: 13)),
          explicit <- maybe(boolean())
        ) do
      %Track{
        provider: :file,
        provider_id: "placeholder",
        title: title,
        artists: artists,
        album: album,
        isrc: isrc,
        duration_seconds: duration,
        track_number: track_number,
        volume_number: disc_number,
        version: version,
        album_upc: upc,
        explicit: explicit
      }
    end
  end

  defp round_trip(tracks) do
    {:ok, parsed} = tracks |> Csv.render() |> IO.iodata_to_binary() |> Csv.parse()
    parsed
  end

  # What a file can carry. Everything else is provenance, not content.
  defp portable(%Track{} = track) do
    Map.take(track, [
      :title,
      :artists,
      :album,
      :isrc,
      :duration_seconds,
      :track_number,
      :volume_number,
      :version,
      :album_upc,
      :explicit
    ])
  end

  property "a playlist survives being written and read back" do
    # The law that matters to a user: export a playlist, import it somewhere
    # else, and nothing the format carries has changed.
    check all(tracks <- list_of(portable_track(), min_length: 1, max_length: 12)) do
      assert Enum.map(round_trip(tracks), &portable/1) == Enum.map(tracks, &portable/1)
    end
  end

  property "writing and reading is a fixpoint after the first pass" do
    # The exact law, and the stronger one. The first round trip *does* change a
    # track — it replaces the provenance with a row number — so identity cannot
    # hold from the start. From then on it must, however many times a playlist
    # goes round: an export of an import of an export is the same playlist.
    check all(tracks <- list_of(portable_track(), min_length: 1, max_length: 12)) do
      once = round_trip(tracks)

      assert round_trip(once) == once
    end
  end

  property "row numbers are assigned in file order, without gaps" do
    # `Track`'s `identifiable` invariant needs them unique; the report needs them
    # to mean "row N of the file you uploaded". Both come from the same counter.
    check all(tracks <- list_of(portable_track(), min_length: 1, max_length: 12)) do
      ids = tracks |> round_trip() |> Enum.map(& &1.provider_id)

      assert ids == Enum.map(1..length(tracks), &Integer.to_string/1)
    end
  end

  property "every track that comes back can be searched for" do
    # The codec contract, checked over generated input rather than over the
    # handful of rows a person thought to write down. A track that fails this
    # would raise `Bond.PreconditionError` inside `search_tracks/3`.
    check all(tracks <- list_of(portable_track(), min_length: 1, max_length: 12)) do
      for track <- round_trip(tracks) do
        assert OnePlaylist.Matching.searchable?(track)
      end
    end
  end

  property "rendering never produces a file that cannot be read back" do
    # `render/2` has no contract of its own — it returns iodata, and there is
    # nothing about iodata worth asserting. This is the property that stands in
    # for one: whatever it writes, `parse/2` accepts.
    check all(tracks <- list_of(portable_track(), min_length: 1, max_length: 12)) do
      assert {:ok, _tracks} = tracks |> Csv.render() |> IO.iodata_to_binary() |> Csv.parse()
    end
  end
end
