defmodule OnePlaylist.Matching.Normalize do
  @moduledoc """
  Turns provider text into something comparable.

  Two services holding the same recording rarely spell it the same way. The
  differences are systematic rather than random, which is what makes this
  tractable:

      "Björk"                          "Bjork"
      "Hey Jude - Remastered 2015"     "Hey Jude (Remastered)"
      "Empire State of Mind (feat.     "Empire State of Mind"
       Alicia Keys)"                    artists: ["JAY-Z", "Alicia Keys"]
      "Don’t Stop Me Now"              "Don't Stop Me Now"

  ## Version tags are extracted, not discarded

  The obvious move is to strip `(Live)`, `(Remastered)` and `(Karaoke Version)`
  as noise so the titles compare equal. That is exactly backwards: those words
  are often the *only* thing distinguishing two different recordings with
  identical artist, title and album. Stripping them makes a karaoke version
  match the original perfectly.

  So they are parsed into `t:tag/0`s and kept, split into two kinds:

    * **Discriminating** — `:live`, `:karaoke`, `:instrumental`, `:acoustic`,
      `:remix`, `:demo`, `:cover`. A different performance. If one side has one
      and the other does not, they are not the same recording, however well the
      text matches.
    * **Editorial** — `:remaster`, `:radio_edit`, `:extended`, `:mono`,
      `:single_version`. The same performance, differently mastered or edited.
      Providers disagree constantly about whether to label these, so treating a
      mismatch as disqualifying would reject far more true matches than it
      catches false ones. They cost a little confidence instead.

  That split is a judgement call, and it is the first thing to revisit when a
  real mismatch is reported.

  Featured artists get the same treatment: pulled out of the title and returned
  as artists, because one service puts them in the title and another in the
  artist list, and dropping them entirely would let a remix featuring someone
  else match the original.
  """

  use Bond

  @typedoc "A recognised version marker."
  @type tag ::
          :live
          | :karaoke
          | :instrumental
          | :acoustic
          | :remix
          | :demo
          | :cover
          | :remaster
          | :radio_edit
          | :extended
          | :mono
          | :single_version

  @typedoc "A title, taken apart."
  @type parsed_title :: %{
          title: String.t(),
          featuring: [String.t()],
          tags: MapSet.t(tag())
        }

  @discriminating [:live, :karaoke, :instrumental, :acoustic, :remix, :demo, :cover]
  @editorial [:remaster, :radio_edit, :extended, :mono, :single_version]

  # Ordered longest-first within each tag so "radio edit" is not consumed by a
  # bare "edit", and matched against already-normalized text.
  @tag_patterns [
    {:karaoke, ["karaoke"]},
    {:instrumental, ["instrumental"]},
    {:acoustic, ["acoustic", "unplugged"]},
    {:live, ["live at", "live from", "live in", "live version", "live"]},
    {:demo, ["demo version", "demo"]},
    {:cover, ["cover version", "made popular by", "in the style of", "tribute to"]},
    {:remix, ["remix", "rmx", "club mix", "dub mix", "vip mix"]},
    {:remaster, ["remaster", "remastered", "remasterizado"]},
    {:radio_edit, ["radio edit", "radio version", "short version"]},
    {:extended, ["extended mix", "extended version", "extended", "full length"]},
    {:mono, ["mono version", "mono"]},
    {:single_version, ["single version", "album version", "original version"]}
  ]

  @featuring_markers ["feat", "ft", "featuring", "with", "w"]

  # Splitting an artist credit happens in two stages, at two different points in
  # the pipeline, and that is the fix for a bug a property test found
  # (`normalize_property_test.exs`, "artists/1 is idempotent through its own
  # output").
  #
  # **Punctuation separates, and must be split on the raw credit.** `text/1`
  # turns "," and "&" into spaces, so splitting after normalizing would merge
  # "JAY-Z, Alicia Keys" into a single name.
  @punctuation_separators ~r/\s*[,&\/+]\s*/u

  # **Separator words are split on the normalized form instead**, which is what
  # makes them reliable. By then the text is lowercased — so the provider's
  # capitalization cannot change the answer, as it did when "Simon and
  # Garfunkel" gave two artists and "Simon AND Garfunkel" gave one — and stripped
  # of punctuation, so "(feat. X)" has become "feat x" and the marker is no
  # longer hidden behind a bracket.
  #
  # The lookarounds are the other half. The previous version used `\bx\b`, for
  # the "Sonny x Cher" convention, and a `\b` boundary is satisfied by the start
  # of the string — so an artist *named* X was its own separator and split into
  # nothing at all. `Normalize.title("Song (feat. X)")` returned `featuring: []`:
  # a credited artist silently dropped, taking the text rung with it, since
  # `artists_agree?/2` answers `false` for an empty set. Requiring a non-space on
  # both sides is what makes a name a name — and it is `\s` rather than `\s+`
  # because `text/1` has already guaranteed single spacing.
  #
  # Splitting in this order is also what makes `artists/1` idempotent, which is
  # load-bearing: `featured_names/1` normalizes a segment and then hands it here,
  # so a second pass over an already-split credit happens on a real path.
  @word_separators ~r/(?<=\S)\s(?:x|and|feat|ft|featuring|with|vs)\s(?=\S)/u

  # The same list, split by what the word actually *means* about the credit.
  #
  # `credits/1` needs the distinction that `artists/1` deliberately throws away.
  # "Neil Young & Pearl Jam" and "Pearl Jam feat. Eddie Vedder" both flatten to
  # a two-name set, and the difference between them is the difference between a
  # collaboration — a recording neither artist made alone — and a credit one
  # service spells out where another does not.
  #
  # `with` is grouped with the featuring markers rather than the co-billing
  # ones, matching how `@featuring_markers` reads it inside a title, and
  # because being wrong in that direction costs a tolerated match rather than a
  # wrong one.
  @featuring_separators ~r/(?<=\S)\s(?:feat|ft|featuring|with)\s(?=\S)/u
  @cobilling_separators ~r/(?<=\S)\s(?:x|and|vs)\s(?=\S)/u

  @doc """
  Case-, accent- and punctuation-insensitive form of a string.

  `nil` normalizes to `""` so callers do not each need a nil branch — a missing
  title and an empty title are equally unmatchable, and treating them the same
  is the honest answer.

      iex> alias OnePlaylist.Matching.Normalize
      iex> Normalize.text("Björk – Jóga (Original)")
      "bjork joga original"
      iex> Normalize.text("Don’t Stop Me Now")
      "dont stop me now"
      iex> Normalize.text(nil)
      ""
  """
  # Three claims about the *output*, not three restatements of the pipeline — and
  # the distinction is the plausible rewrite. Every step below is still present
  # under a reordering, and reordering is what breaks them: strip `\p{Mn}`
  # before the NFKD decomposition and nothing is decomposed yet, so accent
  # folding silently stops; collapse whitespace before turning punctuation into
  # spaces and doubled spaces come back.
  #
  # None of that raises. Each one degrades comparison quietly — a lower Jaro
  # score, a token set that does not intersect — so a transfer reports "no match
  # found" for tracks that are plainly the same, and the match rate drops without
  # anything appearing in a log.
  #
  # These earn their place over the example tests for a reason particular to this
  # function: it is the one place where **every** string from **every** provider
  # arrives. Examples cover the spellings someone thought of; a postcondition
  # covers the Vietnamese stacked diacritic, the Turkish dotted capital and the
  # Arabic harakat in a real user's library. Postconditions are compiled in and
  # gated off in production (see `config/prod.exs`), so "is normalization the
  # reason this user's matches are bad?" is a question answerable from a remote
  # console mid-incident rather than a rebuild.
  #
  # There were four of these. A `decomposed: not Regex.match?(~r/\p{Mn}/u, ...)`
  # sat between the first and second, naming the accent-folding bug directly —
  # until an exhaustive scan showed that no combining mark is also a letter, a
  # digit or a space, so `only_letters_digits_and_spaces` already implies it and
  # it could never fail first. Dropped: a marginally better error message is not
  # worth an assertion that cannot fail independently, evaluated 70,000 times a
  # test run. A leftover combining mark still fails the assertion below.
  @post case_folded: result == String.downcase(result)
  @post only_letters_digits_and_spaces: not Regex.match?(~r/[^\p{L}\p{N} ]/u, result)
  @post single_spaced: result == String.trim(result) and not String.contains?(result, "  ")
  # Added after the other three, and independent of them despite looking like a
  # consequence — which was worth proving rather than assuming, since a
  # `decomposed:` assertion was dropped from this very list for being implied.
  #
  # The three above constrain what the output *looks like*; this one constrains
  # what `text/1` *is*: a projection. Nothing in "lowercase, letters and digits
  # and single spaces, trimmed" forbids a pipeline that keeps changing its
  # answer. Leading-article stripping is the plausible edit that separates them —
  # a standard music-library normalization, and one this module may well want —
  # under which "The The Beatles" normalizes to "the beatles" and then to
  # "beatles", satisfying all three assertions above at every step. The band
  # The The is a real counterexample rather than a contrived one.
  #
  # Idempotence is load-bearing here because the pipeline applies `text/1` twice
  # to the same data: `featured_names/1` normalizes a segment before handing it
  # to `artists/1`, which normalizes each split piece again. A non-projection
  # would make those two passes disagree about one artist's name, silently.
  #
  # Last in the list on purpose. It is the only assertion that re-enters the
  # function, so the three cheaper ones get to fail first and name the problem
  # more precisely. Bond suppresses contract checking while evaluating an
  # assertion — Eiffel's rule — so the nested call terminates instead of
  # recursing forever, and is checked once rather than once per level.
  @post idempotent: text(result) == result
  @spec text(String.t() | nil) :: String.t()
  def text(nil), do: ""

  def text(value) when is_binary(value) do
    value
    |> String.normalize(:nfkd)
    # Everything left behind by NFKD decomposition: the accents themselves.
    # Doing this after decomposition is what makes "ö" and "o" compare equal
    # without a table of special cases.
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[\x{2010}-\x{2015}\x{2212}]/u, "-")
    |> String.replace(~r/[\x{2018}\x{2019}\x{02BC}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}]/u, "\"")
    |> String.replace("&", " and ")
    # Apostrophes close up ("don't" -> "dont") while every other separator
    # becomes a space, so "rock/pop" tokenizes as two words rather than one.
    |> String.replace("'", "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Takes a title apart into its core, its featured artists, and its version tags.

  `version` is the provider's own subtitle field where it has one — TIDAL
  supplies `"Remastered 2015"` there rather than in the title. Passing it here
  means a structured value is read rather than parsed back out of prose.

      iex> alias OnePlaylist.Matching.Normalize
      iex> Normalize.title("Empire State of Mind (feat. Alicia Keys)")
      %{title: "empire state of mind", featuring: ["alicia keys"], tags: MapSet.new()}

      iex> alias OnePlaylist.Matching.Normalize
      iex> parsed = Normalize.title("Hey Jude - Remastered 2015")
      iex> {parsed.title, MapSet.to_list(parsed.tags)}
      {"hey jude", [:remaster]}
  """
  # The most valuable assertion in this module, and the one nothing else states.
  #
  # `tags_in/1` builds from `@tag_patterns`; `discriminating/1` and `editorial/1`
  # partition using `@discriminating` and `@editorial`. Three lists, and nothing
  # holds them in step. Add a pattern for `:acapella` and forget to classify it,
  # and the tag is recognised, parsed, returned — and then dropped by *both*
  # partitions, because it is in neither. `Signals.compare/2` asks only those two
  # questions, so an acapella version compares as a perfect match to the studio
  # recording, which is precisely the failure the whole tag mechanism exists to
  # prevent. Nothing raises, no test fails, and the veto is simply gone.
  @post every_tag_is_classified: MapSet.subset?(result.tags, MapSet.new(known_tags()))
  # Stated as a fixed point rather than as `result.title == text(core)`, which
  # would restate the body. It catches the omission — returning the raw core —
  # and it leans on `text/1` being idempotent, which is a property test rather
  # than a contract because seeing it takes two runs.
  @post title_is_normalized: result.title == text(result.title)
  # A featured artist is pulled out of the title precisely so it can be compared
  # against the *other* provider's artist list. Un-normalized, it never matches
  # one; blank, it is a phantom credit that `dice/2` counts as a member.
  @post featured_artists_are_comparable:
          forall(name <- result.featuring, name == text(name) and name != "")
  @spec title(String.t() | nil, String.t() | nil) :: parsed_title()
  def title(raw, version \\ nil)

  def title(nil, version), do: title("", version)

  def title(raw, version) when is_binary(raw) do
    {core, segments} = split_segments(raw)
    segments = segments ++ List.wrap(version)

    {featuring, rest} = Enum.split_with(segments, &featuring_segment?/1)

    tags =
      [core | rest]
      |> Enum.flat_map(&tags_in/1)
      |> MapSet.new()

    %{
      # A segment that turned out to be a tag is removed from the core title,
      # but a segment that was neither tag nor credit is kept: "(Theme from
      # Shaft)" is part of what the song is called, not decoration.
      title: text(core),
      featuring: featuring |> Enum.flat_map(&featured_names/1) |> Enum.uniq(),
      tags: tags
    }
  end

  @doc """
  Every artist named by a track, normalized, as a set.

  A set rather than a list because credit *order* is not agreed between
  services — one leads with the headliner, another alphabetizes — and comparing
  ordered lists would make that disagreement look like a mismatch.

      iex> alias OnePlaylist.Matching.Normalize
      iex> Normalize.artists(["JAY-Z", "Alicia Keys"]) |> MapSet.to_list() |> Enum.sort()
      ["alicia keys", "jay z"]
  """
  # `no_empty_names` is the one that catches a false *positive* rather than a
  # missed match, which makes it the more dangerous direction. Drop the
  # `Enum.reject(&(&1 == ""))` and a track whose artist credit is punctuation —
  # `"???"`, `"-"`, a stray separator — normalizes to `""` and yields the set
  # `#MapSet<[""]>`. Two such tracks then score `dice/2` = 1.0 on artists: a
  # perfect artist match between two recordings that named nobody at all.
  @post names_are_normalized: forall(name <- result, name == text(name))
  @post no_empty_names: forall(name <- result, name != "")
  @spec artists([String.t()] | String.t() | nil) :: MapSet.t(String.t())
  def artists(nil), do: MapSet.new()
  def artists(value) when is_binary(value), do: artists([value])

  def artists(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, @punctuation_separators, trim: true))
    |> Enum.map(&text/1)
    # No `Enum.reject(&(&1 == ""))` after this, and its absence is deliberate.
    # It was here, and the two-stage split made it unreachable — `trim: true`
    # already drops the empty that a credit like "???" normalizes to. Keeping it
    # would have left `no_empty_names` guarded twice over and falsifiable only by
    # a double mutation, which is another way of saying the contract could never
    # earn its place. Removed, so that losing the `trim: true` above is caught.
    |> Enum.flat_map(&String.split(&1, @word_separators, trim: true))
    |> MapSet.new()
  end

  @doc """
  A credit taken apart into who *made* the recording and who guested on it.

  `artists/1` answers "which names appear", which is the right question for a
  graded similarity and the wrong one for deciding whether two tracks are the
  same recording. These are different claims:

      Neil Young & Pearl Jam    →  primary: neil young, pearl jam
      Pearl Jam feat. Eddie Vedder  →  primary: pearl jam · featured: eddie vedder

  The first is a recording neither artist made alone. The second is one artist's
  recording, described more fully by one service than another. Flattened
  together — which is what `artists/1` does — "Neil Young" looks like a subset
  of the first, and a studio track gets matched to a live collaboration.

      iex> alias OnePlaylist.Matching.Normalize
      iex> credits = Normalize.credits(["Neil Young & Pearl Jam"])
      iex> Enum.sort(credits.primary)
      ["neil young", "pearl jam"]
      iex> credits = Normalize.credits(["Pearl Jam feat. Eddie Vedder"])
      iex> {Enum.sort(credits.primary), Enum.sort(credits.featured)}
      {["pearl jam"], ["eddie vedder"]}
  """
  # Every name goes to exactly one side. A credit that landed in neither would
  # be a collaborator silently dropped, which is the bug this exists to prevent
  # wearing different clothes.
  # The two sides together are exactly what `artists/1` reports, which is the
  # useful form of "no name was lost": the separator lists have to stay a
  # partition of `@word_separators`, and nothing else checks that. Adding a
  # marker to one list and forgetting the other silently drops a collaborator,
  # which is the very bug this function exists to fix wearing other clothes.
  #
  # Two implementations of one rule, cross-checked, in the shape
  # `docs/reference/contracts.md` recommends looking for.
  @post loses_no_name: MapSet.union(result.primary, result.featured) == artists(values)
  @spec credits([String.t()] | String.t() | nil) :: %{
          primary: MapSet.t(String.t()),
          featured: MapSet.t(String.t())
        }
  def credits(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    # Punctuation first, and before normalization, exactly as `artists/1` does:
    # "&" separates co-billed names and `text/1` would strip it.
    |> Enum.flat_map(&String.split(&1, @punctuation_separators, trim: true))
    |> Enum.map(&text/1)
    |> Enum.flat_map(fn name ->
      case String.split(name, @featuring_separators, parts: 2) do
        [lead] -> tagged(:primary, lead)
        [lead, guest] -> tagged(:primary, lead) ++ tagged(:featured, guest)
      end
    end)
    |> classify()
  end

  defp tagged(tag, part) do
    part
    |> String.split(@cobilling_separators, trim: true)
    |> Enum.map(&{tag, &1})
  end

  # "X and the Ys" is a backing band; "X & Y" is two headline acts. The definite
  # article is the marker, and it is why `text/1` keeps leading articles rather
  # than stripping them.
  #
  # This is the difference between Bruce Springsteen and the E Street Band —
  # which every service also lists as plain Bruce Springsteen, for the same
  # recording — and Neil Young & Pearl Jam, which is a recording neither of them
  # made alone. Without it, one rule has to be wrong about one of them.
  #
  # Only past the first name. A lone "The Beatles" is the act, not a backing
  # band for nobody.
  defp classify(names) do
    {primary, featured} =
      names
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{tag, name}, index}, {primary, featured} ->
        if tag == :featured or (index > 0 and backing_band?(name)) do
          {primary, [name | featured]}
        else
          {[name | primary], featured}
        end
      end)

    %{primary: MapSet.new(primary), featured: MapSet.new(featured)}
  end

  # The trailing space matters: "Beatles, The" splits to a bare "the", which is
  # half a scrambled name rather than a band, and belongs with the primary names
  # where `words_agree?` can still put it back together.
  defp backing_band?(name), do: String.starts_with?(name, "the ")

  @doc """
  The distinct words of a normalized string, as a set.

  Used for token-set similarity, which is what makes word order and duplicated
  words stop mattering.
  """
  @spec tokens(String.t() | nil) :: MapSet.t(String.t())
  def tokens(value) do
    value |> text() |> String.split(" ", trim: true) |> MapSet.new()
  end

  # `discriminating/1` and `editorial/1` carry no contract on purpose. The only
  # thing to assert about `MapSet.intersection/2` is that the result is a subset
  # of its input, which describes the mechanism rather than the meaning — and the
  # law that actually matters,
  # that the two partitions between them cover every known tag, is fixed at
  # compile time by three module attributes. That is a test, not a contract:
  # nothing about it can vary at runtime, so an assertion checked on every call
  # would answer the same way forever. See `normalize_test.exs`.
  @doc "The tags that mean a genuinely different performance."
  @spec discriminating(MapSet.t(tag())) :: MapSet.t(tag())
  def discriminating(tags), do: MapSet.intersection(tags, MapSet.new(@discriminating))

  @doc "The tags that mean the same performance, differently mastered or edited."
  @spec editorial(MapSet.t(tag())) :: MapSet.t(tag())
  def editorial(tags), do: MapSet.intersection(tags, MapSet.new(@editorial))

  @doc "Every tag this module knows how to recognise."
  @spec known_tags() :: [tag()]
  def known_tags, do: @discriminating ++ @editorial

  # Pulls out parenthesised and bracketed segments, plus a trailing " - ..."
  # clause, which is the other place providers put this material. Returns the
  # title with them removed, and the segments themselves.
  defp split_segments(raw) do
    {without_brackets, bracketed} = extract_bracketed(raw)
    {core, trailing} = extract_trailing(without_brackets)

    {core, bracketed ++ trailing}
  end

  defp extract_bracketed(raw) do
    segments =
      ~r/[\(\[]([^\)\]]*)[\)\]]/u
      |> Regex.scan(raw, capture: :all_but_first)
      |> List.flatten()

    {String.replace(raw, ~r/[\(\[][^\)\]]*[\)\]]/u, " "), segments}
  end

  # Only a trailing dash clause, and only when the dash is surrounded by spaces.
  # "Hey Jude - Remastered" splits; "Jay-Z" and "Ne-Yo" must not.
  defp extract_trailing(raw) do
    case String.split(raw, ~r/\s+-\s+/u, parts: 2) do
      [core, trailing] -> {core, [trailing]}
      [core] -> {core, []}
    end
  end

  defp featuring_segment?(segment) do
    case String.split(text(segment), " ", parts: 2) do
      [marker, _rest] -> marker in @featuring_markers
      _single_word -> false
    end
  end

  defp featured_names(segment) do
    [_marker, names] = String.split(text(segment), " ", parts: 2)

    names |> artists() |> MapSet.to_list() |> Enum.sort()
  end

  defp tags_in(segment) do
    normalized = text(segment)

    for {tag, patterns} <- @tag_patterns,
        Enum.any?(patterns, &contains_word?(normalized, &1)),
        do: tag
  end

  # Whole-phrase match, so "livermore" does not read as `:live` and "demolition"
  # does not read as `:demo`.
  defp contains_word?(haystack, phrase) do
    Regex.match?(~r/(?<!\p{L})#{Regex.escape(phrase)}(?!\p{L})/u, haystack)
  end
end
