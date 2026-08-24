defmodule OnePlaylist.Matching.Strategy.WorkTest do
  @moduledoc """
  Rung 3, against the shapes a real classical catalogue produces.
  """

  use ExUnit.Case, async: true

  import OnePlaylist.MusicFixtures

  alias OnePlaylist.Matching

  describe "a classical recording" do
    test "matches across a composer credit and a performer credit" do
      # The failure that made classical match 0 of 8. The source credits the
      # composer and TIDAL credits the performer, so no rung comparing artists
      # with artists can ever fire.
      source =
        track(
          title: "The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro",
          artists: ["Antonio Vivaldi"],
          album: "A Treasury of Baroque"
        )

      candidate =
        track(
          title:
            ~s(The Four Seasons, Violin Concerto in E Major, Op. 8 No. 1, RV 269 "Spring": I. Allegro),
          artists: ["Nigel Kennedy"],
          album: "Vivaldi: The Four Seasons",
          provider_id: "c1"
        )

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :work
    end

    test "prefers the right concerto over a better-scoring wrong one" do
      # Compared as words, Winter scored 0.494 against Spring's 0.425 for a
      # Spring query. The opus number decides it instead.
      source =
        track(
          title: "The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro",
          artists: ["Antonio Vivaldi"]
        )

      winter =
        track(
          title:
            ~s(The Four Seasons - Violin Concerto in F Minor, Op. 8 No. 4, RV 297 "Winter": I. Allegro non molto),
          artists: ["Joshua Bell"],
          album: "Vivaldi: The Four Seasons",
          provider_id: "winter"
        )

      spring =
        track(
          title: ~s(Violin Concerto in E Major, Op. 8 No. 1, RV 269 "Spring": I. Allegro),
          artists: ["Nigel Kennedy"],
          album: "Vivaldi: The Four Seasons",
          provider_id: "spring"
        )

      assert {:ok, match} = Matching.match(source, [winter, spring])
      assert match.track.provider_id == "spring"
    end

    test "refuses a different movement of the same work" do
      source =
        track(
          title: "Symphony No. 1 in C major, Op. 21: I. Adagio",
          artists: ["Ludwig van Beethoven"]
        )

      other =
        track(
          title: "Beethoven: Symphony No. 1 in C Major, Op. 21: II. Andante cantabile",
          artists: ["Berliner Philharmoniker"],
          provider_id: "c1"
        )

      assert {:error, _reason} = Matching.match(source, [other])
    end

    test "refuses a concerto for a different instrument with the same number" do
      # Both are Vivaldi, both "No. 2 in G minor", and the instrument is the
      # only thing that separates them. The generic form "concerto" cannot
      # carry the match on its own.
      source =
        track(
          title: "Concerto for Two Cellos and Orchestra No. 2 in G minor: Allegro",
          artists: ["Antonio Vivaldi"]
        )

      violin =
        track(
          title:
            ~s|Concerto In G Minor for Violin, String Orchestra and Continuo, Op. 8, No. 2, RV 315, "L'estate" (Summer). Allegro non molto|,
          artists: ["Antonio Vivaldi"],
          album: "Vivaldi : The 4 seasons",
          provider_id: "c1"
        )

      assert {:error, _reason} = Matching.match(source, [violin])
    end

    test "needs the composer to appear somewhere in the candidate" do
      # The credit is how a wrong composer's identically-numbered work is kept
      # out, since the work signature alone cannot tell them apart.
      source =
        track(
          title: "Symphony No. 1 in C major, Op. 21: I. Adagio",
          artists: ["Ludwig van Beethoven"]
        )

      elsewhere =
        track(
          title: "Symphony No. 1 in C Major, Op. 21: I. Adagio",
          artists: ["Some Other Orchestra"],
          album: "Unrelated Collection",
          provider_id: "c1"
        )

      assert {:error, _reason} = Matching.match(source, [elsewhere])
    end

    test "matches on a catalogue number supplied from outside" do
      # The case the local rung cannot do: "Concerto Alexander Feast" names its
      # piece exactly, gives no catalogue number, and "concerto" is too generic
      # a form to stand in. Every catalogue TIDAL carries writes HWV 318.
      #
      # `work_titles` is what `OnePlaylist.MusicBrainz.works/3` returns, and it
      # is empty unless the ladder has already failed.
      source =
        track(title: "Concerto Alexander Feast: Allegro", artists: ["George Frideric Handel"])

      candidate =
        track(
          title: ~s|Handel: Concerto Grosso in C Major, HWV 318 "Alexander's Feast": I. Allegro|,
          artists: ["Academy of St Martin in the Fields"],
          provider_id: "c1"
        )

      assert {:error, _} = Matching.match(source, [candidate]),
             "without the outside answer there is nothing to match on"

      enriched =
        Map.put(source, :work_titles, [
          ~s|Concerto grosso in C major, HWV 318 "Alexander's Feast"|
        ])

      assert {:ok, match} = Matching.match(enriched, [candidate])
      assert match.strategy == :work
    end

    test "the outside answer does not overrule the movement the file names" do
      # A work lookup answers "what is this piece called", not "which movement
      # did you mean". Merging must not let it rewrite the source's own reading.
      source =
        track(title: "Concerto Alexander Feast: Allegro", artists: ["George Frideric Handel"])
        |> Map.put(:work_titles, [~s|Concerto grosso in C major, HWV 318: II. Largo|])

      other_movement =
        track(
          title: "Handel: Concerto Grosso in C Major, HWV 318: II. Largo",
          artists: ["Academy of St Martin in the Fields"],
          provider_id: "c1"
        )

      assert {:error, _reason} = Matching.match(source, [other_movement])
    end

    test "does not fire on a pop song" do
      # The rung is restricted to classical by the shape of the title rather
      # than by a guess about genre, and this is what that means in practice.
      source = track(title: "Yesterday", artists: ["The Beatles"])
      candidate = track(title: "Yesterday", artists: ["The Beatles"], provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])
      refute match.strategy == :work
    end
  end
end
