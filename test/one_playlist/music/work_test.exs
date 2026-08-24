defmodule OnePlaylist.Music.WorkTest do
  @moduledoc """
  Reading a classical work out of a title.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Music.Work

  doctest OnePlaylist.Music.Work

  describe "parse/1" do
    test "reads a catalogue number in any of its systems" do
      for {title, expected} <- [
            {"Toccata and Fugue in D Minor, BWV 565", {"bwv", "565", nil}},
            {"Serenade No. 13 in G major, K. 525", {"k", "525", nil}},
            {"The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro", {"op", "8", "1"}},
            # The slash form of a sub-number, which Brahms editions use.
            {"Sonata No. 1 in F minor, Op. 120/1: I. Allegro", {"op", "120", "1"}}
          ] do
        assert expected in MapSet.to_list(Work.parse(title).catalogue),
               "failed for #{title}"
      end
    end

    test "keeps both systems when a title gives two" do
      # Either may be the one the other catalogue used, so neither can be
      # dropped.
      work = Work.parse(~s(Violin Concerto in E Major, Op. 8 No. 1, RV 269 "Spring": I. Allegro))

      assert {"op", "8", "1"} in MapSet.to_list(work.catalogue)
      assert {"rv", "269", nil} in MapSet.to_list(work.catalogue)
    end

    test "reads a movement by either convention" do
      assert Work.parse("Symphony No. 7, Op. 92: II. Allegretto").roman == "ii"
      assert Work.parse("Organ Concerto, Op. 7 No. 4: Adagio").tempo == "adagio"
    end

    test "folds diacritics, so an accented title reads like an unaccented one" do
      assert Work.parse("Préludes: no. 10").number == Work.parse("Preludes: no. 10").number
    end
  end

  describe "same_work?/2" do
    test "a shared catalogue number is enough" do
      source = Work.parse("The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro")
      same = Work.parse(~s(Violin Concerto in E Major, Op. 8 No. 1, RV 269 "Spring": I. Allegro))

      assert Work.same_work?(source, same)
      assert Work.identified_by(source, same) == :catalogue
    end

    test "a different opus number is a different work" do
      # The case that made classical match 0 of 8: compared as words, Winter
      # scored *higher* than Spring for a Spring query.
      spring = Work.parse("The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro")
      winter = Work.parse(~s(Op. 8 No. 4, RV 297 "Winter": I. Allegro non molto))

      refute Work.same_work?(spring, winter)
    end

    test "a generic form and a number are not enough on their own" do
      # Vivaldi wrote a Concerto for Two Cellos No. 2 in G minor and a violin
      # concerto also numbered 2 in G minor. "Concerto" plus "2" plus "G minor"
      # agrees for both, and this rung matched them to each other until the
      # generic forms were refused.
      cellos = Work.parse("Concerto for Two Cellos and Orchestra No. 2 in G minor: Allegro")
      violin = Work.parse("Concerto In G Minor for Violin, String Orchestra: Allegro non molto")

      refute Work.same_work?(cellos, violin)
    end

    test "a qualified form and a number are" do
      # "Brandenburg Concerto No. 2" names one piece; "Concerto No. 2" does not.
      source = Work.parse("Brandenburg Concerto no. 2 in F major: Allegro assai")
      found = Work.parse("Brandenburg Concerto No. 2 in F Major, BWV 1047: III. Allegro assai")

      assert Work.same_work?(source, found)
      assert Work.identified_by(source, found) == :form
    end

    test "a stated key that disagrees overrules the rest" do
      major = Work.parse("Concerto grosso in C major, Op. 3 No. 12: Largo")
      minor = Work.parse("Concerto grosso in C minor, Op. 3 No. 12: Largo")

      refute Work.same_work?(major, minor)
    end

    test "a pop song names no work at all" do
      refute Work.identifies_work?(Work.parse("Yesterday"))
      refute Work.same_work?(Work.parse("Yesterday"), Work.parse("Yesterday"))
    end
  end

  describe "same_movement?/2" do
    test "silence is not disagreement" do
      # A single-movement work, or a title that names none. Only a stated
      # difference counts.
      assert Work.same_movement?(Work.parse("Ave Maria, Op. 52"), Work.parse("Ave Maria, Op. 52"))
    end

    test "but a stated difference is" do
      refute Work.same_movement?(
               Work.parse("Symphony No. 1, Op. 21: I. Adagio"),
               Work.parse("Symphony No. 1, Op. 21: II. Andante")
             )
    end
  end
end
