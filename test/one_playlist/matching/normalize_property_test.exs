defmodule OnePlaylist.Matching.NormalizePropertyTest do
  @moduledoc """
  The normalizer, driven over text no one would think to write down.

  ## What these can and cannot show

  `Normalize` is pure and total, so its postconditions cannot be made to fire by
  *data* — only by a change to the code. That was measured rather than assumed:
  every codepoint in the BMP and the first astral plane was pushed through
  `text/1` alone, embedded between letters, and doubled — 128,992 codepoints,
  ~387,000 inputs — and none violated any postcondition. The scan is not kept as
  a test because it takes far longer than the suite it would live in; the result
  is recorded in `docs/reference/contracts.md`.

  So these properties are **regression harnesses, not bug hunts**. Their job is
  to make a future edit to the pipeline fail loudly, over a far wider slice of
  input than the example tests in `normalize_test.exs` reach. That is the same
  bargain `SimilarityPropertyTest` makes, and it is worth being explicit that
  `⚠ never failed` against these assertions is the expected steady state rather
  than a prompt to delete them.

  ## The laws that are *not* contracts

  Two of the properties below take two runs to see and have no natural home in a
  contract, because each compares the results of two *different* calls rather
  than constraining one:

    * **`artists/1` does not care which separator a provider chose.** `"A & B"`,
      `"A, B"` and `"A and B"` are the same credit, and the whole reason the
      separator regex exists.
    * **`title/2` does not care where the provider put the version marker.** In
      brackets, after a dash, or in its own field — three places, and TIDAL uses
      a different one from Navidrome. Reading them differently is the bug the
      module was written to prevent.

  Idempotence used to be listed here and no longer is. It compares two calls
  too, but both are calls on the *same* value, so a postcondition can state it
  by re-entering the function — which is where it now lives. See
  `docs/reference/contracts.md`; getting that wrong is what kept it out of the
  contract in the first place.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.PropertyTest

  alias OnePlaylist.Matching.Normalize

  # Deliberately hostile, and weighted toward the characters that make
  # normalization non-trivial rather than toward random noise. A generator of
  # plain alphanumerics would drive the pipeline's easy path a thousand times
  # and prove nothing about it.
  defp nasty_fragment do
    StreamData.one_of([
      StreamData.string(:alphanumeric, max_length: 8),
      StreamData.member_of([
        # Precomposed vs decomposed forms of the same thing.
        "Björk",
        "Björk",
        "Jóga",
        "Jóga",
        # Case mappings that are not a simple one-to-one.
        "İstanbul",
        "STRASSE",
        "Straße",
        "ΟΔΥΣΣΕΥΣ",
        # NFKD does real work on these: ligatures, fullwidth, Roman numerals,
        # superscripts — all of which decompose into ASCII.
        "ﬁre",
        "Ｈｅｌｌｏ",
        "Ⅻ",
        "x²",
        # Scripts with marks the example tests never mention.
        "Tiếng Việt",
        "עִבְרִית",
        "العَرَبِيَّة",
        "日本語",
        # Punctuation and separators.
        "Don’t",
        "rock/pop",
        "A & B",
        "—",
        "…",
        "(feat. X)",
        "  ",
        "\t\n",
        "",
        # Emoji and invisibles, which are neither letters nor spaces.
        "🎵",
        "a‍b",
        " "
      ])
    ])
  end

  defp text_generator do
    StreamData.map(
      StreamData.list_of(nasty_fragment(), max_length: 5),
      &Enum.join(&1, " ")
    )
  end

  defp maybe(generator), do: StreamData.one_of([generator, StreamData.constant(nil)])

  defp artists_generator do
    StreamData.list_of(
      StreamData.one_of([
        text_generator(),
        StreamData.member_of([
          "JAY-Z, Alicia Keys",
          "Simon & Garfunkel",
          "A / B",
          "A + B",
          "Sonny x Cher",
          "Nick Cave and the Bad Seeds",
          "Queen feat. David Bowie",
          "???",
          "-",
          ","
        ])
      ]),
      max_length: 4
    )
  end

  # ── The contracts, as the oracle ────────────────────────────────────────────

  contract_holds(&Normalize.text/1, args: [maybe(text_generator())])

  contract_holds(&Normalize.title/2, args: [maybe(text_generator()), maybe(text_generator())])

  contract_holds(&Normalize.artists/1, args: [artists_generator()])

  # ── The laws that need two runs ─────────────────────────────────────────────

  describe "text/1" do
    # `property "is idempotent"` lived here until idempotence became a
    # postcondition on `text/1` itself, at which point `contract_holds/2` above
    # drove it over the same generator and this said the same thing twice.
    # Removed rather than kept for visibility, on the same grounds as the
    # redundant guard deleted from `artists/1`.
    property "never invents content out of nothing" do
      # A normalizer that produced output from empty-ish input would be matching
      # on an artefact of its own making.
      check all(raw <- StreamData.member_of(["", "   ", "\t", "…", "—", "🎵", " "])) do
        assert Normalize.text(raw) == ""
      end
    end
  end

  describe "artists/1" do
    property "does not care which separator the provider chose" do
      # The reason @artist_separators exists. One service writes "A & B",
      # another "A, B", a third "A and B"; all three are the same credit, and a
      # disagreement here makes every cross-service artist comparison fail.
      check all(
              left <- StreamData.member_of(~w(bowie queen abba)),
              right <- StreamData.member_of(~w(eno mercury frida)),
              separator <-
                StreamData.member_of([" & ", ", ", " and ", " / ", " + ", " x ", " feat. "])
            ) do
        assert Normalize.artists(["#{left}#{separator}#{right}"]) ==
                 MapSet.new([left, right])
      end
    end

    property "is idempotent through its own output" do
      check all(values <- artists_generator()) do
        once = Normalize.artists(values)

        assert Normalize.artists(MapSet.to_list(once)) == once
      end
    end
  end

  describe "title/2" do
    property "reads a version marker the same wherever the provider put it" do
      # Three places, and providers genuinely differ: TIDAL supplies a separate
      # version field, Navidrome's ID3 tags put it in brackets, and plenty of
      # libraries use a trailing dash. Reading them differently would mean the
      # same recording tagged two ways compares as two recordings.
      check all(
              base <- StreamData.member_of(["Hey Jude", "Omaha", "Sitting by the Window"]),
              {phrase, tag} <-
                StreamData.member_of([
                  {"Live", :live},
                  {"Remastered", :remaster},
                  {"Karaoke", :karaoke},
                  {"Radio Edit", :radio_edit},
                  {"Acoustic", :acoustic}
                ])
            ) do
        bracketed = Normalize.title("#{base} (#{phrase})")
        dashed = Normalize.title("#{base} - #{phrase}")
        fielded = Normalize.title(base, phrase)

        for parsed <- [bracketed, dashed, fielded] do
          assert tag in parsed.tags, "#{phrase} was not recognised in every position"
          assert parsed.title == Normalize.text(base)
        end
      end
    end

    property "a featured artist named in the title is never lost" do
      # Dropping it entirely would let a remix featuring someone else match the
      # original, which is the case the moduledoc calls out.
      check all(
              base <- StreamData.member_of(["Empire State of Mind", "Under Pressure"]),
              marker <- StreamData.member_of(~w(feat. ft. featuring with)),
              guest <- StreamData.member_of(["Alicia Keys", "David Bowie", "Nile Rodgers"])
            ) do
        parsed = Normalize.title("#{base} (#{marker} #{guest})")

        assert Normalize.text(guest) in parsed.featuring
        refute parsed.title =~ Normalize.text(guest)
      end
    end
  end

  describe "the generator reaches what it claims to" do
    property "hostile text actually exercises the interesting branches" do
      # The guard SimilarityPropertyTest taught this codebase to write. Without
      # it the generator could drift to alphanumerics and the properties above
      # would pass over text that needed no normalizing at all.
      samples = Enum.take(text_generator(), 300)

      needed_folding =
        Enum.count(samples, fn raw ->
          raw != "" and Normalize.text(raw) != String.trim(raw)
        end)

      collapsed_to_nothing = Enum.count(samples, &(Normalize.text(&1) == "" and &1 != ""))

      assert needed_folding > 100,
             "only #{needed_folding}/300 generated strings actually needed normalizing"

      # Deliberately a low bar. A joined run of up to five fragments is rarely
      # *all* punctuation, so this lands around 4 in 300 — enough to know the
      # "normalizes away to nothing" path is exercised, and a threshold set from
      # the measured distribution rather than from an optimistic guess.
      assert collapsed_to_nothing > 2,
             "only #{collapsed_to_nothing}/300 generated strings normalized away entirely"
    end
  end
end
