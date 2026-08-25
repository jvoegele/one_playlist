defmodule OnePlaylist.Matching.NormalizeTest do
  @moduledoc """
  The normalization rules, stated as the differences they are meant to absorb.

  Each test names a real way two services spell the same recording differently.
  When a mismatch is reported in production, this is where the reproduction
  goes.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Matching.Normalize

  doctest OnePlaylist.Matching.Normalize

  describe "text/1 absorbs spelling differences" do
    test "diacritics" do
      assert Normalize.text("Björk") == Normalize.text("Bjork")
      assert Normalize.text("Beyoncé") == Normalize.text("Beyonce")
      assert Normalize.text("Sigur Rós") == Normalize.text("Sigur Ros")
    end

    test "case" do
      assert Normalize.text("JAY-Z") == Normalize.text("Jay-Z")
    end

    test "curly and straight quotes" do
      assert Normalize.text("Don’t Stop Me Now") == Normalize.text("Don't Stop Me Now")
    end

    test "the several Unicode dashes" do
      assert Normalize.text("Jay–Z") == Normalize.text("Jay-Z")
      assert Normalize.text("Jay—Z") == Normalize.text("Jay-Z")
    end

    test "ampersand and the word" do
      assert Normalize.text("Simon & Garfunkel") == Normalize.text("Simon and Garfunkel")
    end

    test "punctuation and spacing" do
      assert Normalize.text("  Hey,  Jude!! ") == Normalize.text("Hey Jude")
    end

    test "an apostrophe closes up rather than splitting the word" do
      # "dont", not "don t" — otherwise the token set gains a bare "t" and
      # every contraction looks like an extra word.
      assert Normalize.text("Don't") == "dont"
    end
  end

  describe "title/2 separates the title from what is said about it" do
    test "a featured artist becomes an artist" do
      parsed = Normalize.title("Empire State of Mind (feat. Alicia Keys)")

      assert parsed.title == "empire state of mind"
      assert parsed.featuring == ["alicia keys"]
    end

    test "every spelling of the featuring marker" do
      for marker <- ["feat.", "ft.", "featuring", "with"] do
        parsed = Normalize.title("Song (#{marker} Nile Rodgers)")

        assert parsed.featuring == ["nile rodgers"], "failed for #{marker}"
        assert parsed.title == "song"
      end
    end

    test "several featured artists" do
      parsed = Normalize.title("Song (feat. A Tribe Called Quest & Busta Rhymes)")

      assert parsed.featuring == ["a tribe called quest", "busta rhymes"]
    end

    test "a trailing dash clause is a segment" do
      parsed = Normalize.title("Hey Jude - Remastered 2015")

      assert parsed.title == "hey jude"
      assert MapSet.to_list(parsed.tags) == [:remaster]
    end

    test "a hyphenated name is not a trailing clause" do
      # The dash must be surrounded by spaces. Otherwise "Ne-Yo" and "Jay-Z"
      # lose half their name.
      assert Normalize.title("Ne-Yo").title == "ne yo"
      assert Normalize.title("So Sick - Ne-Yo").title == "so sick"
    end

    test "the provider's own version field is read, not just the title" do
      parsed = Normalize.title("Hey Jude", "Remastered 2015")

      assert parsed.title == "hey jude"
      assert MapSet.member?(parsed.tags, :remaster)
    end

    test "a segment that is neither a credit nor a tag stays in the title" do
      # "(Theme from Shaft)" is part of what the song is called. Stripping every
      # parenthetical would merge genuinely different songs.
      parsed = Normalize.title("Theme from Shaft")

      assert parsed.title == "theme from shaft"
    end

    test "a nil title is empty rather than an error" do
      assert Normalize.title(nil).title == ""
    end
  end

  describe "version tags" do
    test "each discriminating tag is recognised" do
      cases = [
        {"Yesterday (Live)", :live},
        {"Yesterday (Live at Shea Stadium)", :live},
        {"Yesterday (Karaoke Version)", :karaoke},
        {"Yesterday (Instrumental)", :instrumental},
        {"Yesterday (Acoustic)", :acoustic},
        {"Yesterday (Unplugged)", :acoustic},
        {"Yesterday (Sped Up Remix)", :remix},
        {"Yesterday (Demo)", :demo},
        {"Yesterday (In the Style of The Beatles)", :cover}
      ]

      for {title, expected} <- cases do
        tags = Normalize.title(title).tags

        assert MapSet.member?(tags, expected), "#{title} did not yield #{expected}"

        assert MapSet.size(Normalize.discriminating(tags)) > 0,
               "#{title} should be discriminating"
      end
    end

    test "each editorial tag is recognised, and is not discriminating" do
      cases = [
        {"Yesterday (Remastered)", :remaster},
        {"Yesterday (Radio Edit)", :radio_edit},
        {"Yesterday (Extended Mix)", :extended},
        {"Yesterday (Mono Version)", :mono},
        {"Yesterday (Single Version)", :single_version}
      ]

      for {title, expected} <- cases do
        tags = Normalize.title(title).tags

        assert MapSet.member?(tags, expected), "#{title} did not yield #{expected}"

        assert MapSet.size(Normalize.discriminating(tags)) == 0,
               "#{title} must not be discriminating — providers label these inconsistently"
      end
    end

    test "a tag is matched as a whole word" do
      # The reason `contains_word?/2` exists. Without it "Demolition" is a demo
      # and "Livermore" is a live recording — and a veto fires on a track that
      # is simply named something.
      assert Normalize.title("Demolition Man").tags == MapSet.new()
      assert Normalize.title("Livermore").tags == MapSet.new()
      assert Normalize.title("Remixology").tags == MapSet.new()
    end

    test "a plain title has no tags at all" do
      assert Normalize.title("Yesterday").tags == MapSet.new()
    end
  end

  describe "artists/1" do
    test "splits every separator services actually use" do
      for credit <- ["A & B", "A, B", "A and B", "A feat. B", "A / B", "A x B", "A vs B"] do
        assert Normalize.artists([credit]) == MapSet.new(["a", "b"]), "failed for #{credit}"
      end
    end

    test "normalizes each name" do
      assert Normalize.artists(["JAY-Z", "Beyoncé"]) == MapSet.new(["jay z", "beyonce"])
    end

    test "ignores non-strings rather than raising" do
      # `artists` comes from a provider payload, and a contract in the mapper
      # guards the output — but this must not be the thing that raises.
      assert Normalize.artists([nil, "A", %{}]) == MapSet.new(["a"])
    end

    test "nil is an empty set" do
      assert Normalize.artists(nil) == MapSet.new()
    end
  end

  describe "an artist whose name is also a separator" do
    test "a band called X is not split into nothing" do
      # Found by a property test, not by anyone reading the regex. The separator
      # list carries `x` for the "Sonny x Cher" convention, and a `\b` boundary
      # is satisfied by the start of the string — so the name was its own
      # separator and split away entirely.
      assert Normalize.artists(["X"]) |> MapSet.to_list() == ["x"]
      assert Normalize.artists(["x"]) |> MapSet.to_list() == ["x"]
      assert Normalize.artists(["X Japan"]) |> MapSet.to_list() == ["x japan"]
    end

    test "a featured artist called X survives being pulled out of the title" do
      # The path that made it reachable rather than theoretical:
      # `featured_names/1` normalizes — and so lowercases — before splitting, so
      # the uppercase spelling that accidentally protected the artist field was
      # already gone by the time the credit was split.
      assert Normalize.title("Song (feat. X)").featuring == ["x"]

      assert Normalize.title("Song (feat. X & Alicia Keys)").featuring ==
               ["alicia keys", "x"]
    end

    test "a band whose name starts with a separator word is not split" do
      assert Normalize.artists(["And Also The Trees"]) |> MapSet.to_list() ==
               ["and also the trees"]
    end

    test "the collaboration convention still splits" do
      assert Normalize.artists(["Sonny x Cher"]) |> MapSet.to_list() == ["cher", "sonny"]
    end
  end

  describe "capitalization does not decide how many artists there are" do
    test "a separator word is recognised whatever case the provider used" do
      # The split runs on the raw credit, and every separator alternative was
      # lowercase, so "Simon and Garfunkel" gave two artists and "Simon AND
      # Garfunkel" gave one. Two providers spelling the same credit differently
      # would disagree about the artist set, which is the one thing this module
      # exists to prevent.
      for credit <- ["Simon and Garfunkel", "Simon AND Garfunkel", "Simon And Garfunkel"] do
        assert Normalize.artists([credit]) |> MapSet.to_list() |> Enum.sort() ==
                 ["garfunkel", "simon"],
               "#{credit} was split differently"
      end
    end

    test "a marker with a trailing dot is still a marker" do
      assert Normalize.artists(["Queen feat. David Bowie"]) |> MapSet.to_list() ==
               ["david bowie", "queen"]
    end
  end

  describe "the tag tables agree with each other" do
    test "every tag the patterns can produce is classified as one kind or the other" do
      # Three module attributes — @tag_patterns, @discriminating, @editorial —
      # and nothing but this holds them in step. A tag recognised but classified
      # as neither is dropped by `discriminating/1` *and* by `editorial/1`, so
      # `Signals.compare/2` never sees it: the marker parses, and the veto it
      # exists to trigger silently does not happen.
      #
      # A test rather than a contract because the tables are compile-time
      # constants. `title/2` carries the runtime half — see
      # `every_tag_is_classified` there — which is what catches a phrase no test
      # happens to use.
      known = MapSet.new(Normalize.known_tags())

      classified =
        MapSet.union(
          Normalize.discriminating(known),
          Normalize.editorial(known)
        )

      assert MapSet.equal?(classified, known),
             "unclassified: #{inspect(MapSet.difference(known, classified) |> MapSet.to_list())}"
    end

    test "no tag is both a different performance and a different master" do
      assert MapSet.disjoint?(
               Normalize.discriminating(MapSet.new(Normalize.known_tags())),
               Normalize.editorial(MapSet.new(Normalize.known_tags()))
             )
    end
  end

  describe "a title that is entirely a bracketed segment" do
    test "falls back to the whole title rather than emptying out" do
      # Pearl Jam's official bootlegs list an unnamed jam as "[improvisation]".
      # Stripping the segment leaves nothing, and an empty title is worse than a
      # decorated one: enrichment asks MusicBrainz for the empty string and gets
      # ten arbitrary recordings by that artist, while `title_similarity/2`
      # scores "" against every candidate at zero — so the ladder could not
      # accept one even if the search were good.
      assert Normalize.title("[improvisation]").title == "improvisation"
      assert Normalize.title("(untitled)").title == "untitled"
    end

    test "and a title that is only a version tag still classifies as one" do
      # The fallback must not turn a tag into a name. "(Live)" as a whole title
      # is pathological either way, but the tag is what the veto reads.
      parsed = Normalize.title("Nothing As It Seems (Live)")

      assert parsed.title == "nothing as it seems"
      assert :live in parsed.tags
    end

    test "an ordinary title is untouched" do
      assert Normalize.title("Hard to Imagine").title == "hard to imagine"
    end
  end
end
