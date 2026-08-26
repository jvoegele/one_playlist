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
  # The lookarounds are the other half, and `\b` will not do. A word boundary is
  # satisfied by the start of the string, so under `\bx\b` — there for the
  # "Sonny x Cher" convention — an artist *named* X is its own separator and
  # splits into nothing at all: `Normalize.title("Song (feat. X)")` yields
  # `featuring: []`, a credited artist silently dropped, taking the text rung
  # with it since an empty credit set cannot agree with anything. Requiring a
  # non-space on both sides is what makes a name a name — and it is `\s` rather
  # than `\s+` because `text/1` has already guaranteed single spacing.
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
  # `with` co-bills here, and is a *guest* marker inside a title — the two are
  # genuinely different and `@featuring_markers` above is right for its own job.
  # "Song (with X)" names a guest on one artist's recording. "A with B", as a
  # credit, names a recording the two made together: Neil Young *with* Pearl Jam
  # is the Mirror Ball collaboration, not a Neil Young track Pearl Jam appear on.
  # A local library spells that collaboration "with" where a Roon export spells
  # it "&", so the two have to reach the same answer.
  @featuring_separators ~r/(?<=\S)\s(?:feat|ft|featuring)\s(?=\S)/u
  @cobilling_separators ~r/(?<=\S)\s(?:x|and|with|vs)\s(?=\S)/u

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

  ## What "normalized" means

  The four postconditions below are the definition, and they are claims about the
  *output* rather than restatements of the pipeline. Every step survives a
  reordering, and reordering is what breaks them: strip `\p{Mn}` before the NFKD
  decomposition and nothing is decomposed yet, so accent folding silently stops;
  collapse whitespace before turning punctuation into spaces and doubled spaces
  come back.

  None of that raises. Each degrades comparison quietly — a lower Jaro score, a
  token set that does not intersect — so a transfer reports "no match found" for
  tracks that are plainly the same, and the match rate drops with nothing in a
  log.

  They earn their place over example tests for a reason particular to this
  function: it is the one place where **every** string from **every** provider
  arrives. Examples cover the spellings someone thought of; a postcondition
  covers the Vietnamese stacked diacritic, the Turkish dotted capital and the
  Arabic harakat in a real user's library.
  """
  # Three and not four: a `decomposed:` assertion naming the accent-folding bug
  # cannot fail independently, because no combining mark is also a letter, digit
  # or space — an exhaustive scan confirms it — so
  # `only_letters_digits_and_spaces` already implies it. A leftover combining
  # mark still fails that one.
  @post case_folded: result == String.downcase(result)
  @post only_letters_digits_and_spaces: not Regex.match?(~r/[^\p{L}\p{N} ]/u, result)
  @post single_spaced: result == String.trim(result) and not String.contains?(result, "  ")
  # Independent of the three above rather than implied by them, which is worth
  # proving: they constrain what the output *looks like*, this constrains what
  # `text/1` **is** — a projection. Leading-article stripping is the plausible
  # edit that separates them, under which "The The Beatles" becomes "the beatles"
  # and then "beatles", satisfying all three at every step. The band The The is a
  # real counterexample, not a contrived one. It matters because the pipeline
  # applies `text/1` twice to the same data — `featured_names/1` normalizes a
  # segment that `artists/1` then normalizes again.
  #
  # Last so the cheaper three fail first, and sound only because Meyer's
  # Assertion Evaluation rule suppresses contracts while an assertion runs.
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

  **Every tag returned is one the comparison rules know how to use** —
  `every_tag_is_classified` below, and the most valuable assertion in this
  module. `tags_in/1` builds from one list and the discriminating/editorial
  partition from two others, and nothing else holds the three in step. Add a
  pattern for `:acapella` and forget to classify it, and the tag is recognised,
  parsed and returned — then dropped by *both* partitions, because it is in
  neither. `Signals.compare/2` asks only those two questions, so an acapella
  version compares as a perfect match to the studio recording. Nothing raises, no
  test fails, and the veto is simply gone.
  """
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
      title: core_or_whole(core, raw),
      featuring: featuring |> Enum.flat_map(&featured_names/1) |> Enum.uniq(),
      tags: tags
    }
  end

  # A title that is *entirely* a bracketed segment leaves nothing behind, and an
  # empty title is worse than a decorated one: `Enrichment.by_name/1` asks
  # MusicBrainz for the empty string, gets ten arbitrary recordings by that
  # artist, and declines all ten — while `title_similarity/2` scores "" against
  # every candidate at zero, so the ladder could not accept one even if the
  # search were good.
  #
  # Found on a real library. Pearl Jam's official bootlegs list an unnamed jam as
  # **"[improvisation]"**, which is the whole title in brackets.
  #
  # `album/1` has had this fallback since it was written — `"" -> text(title)` —
  # and the asymmetry was the bug rather than a decision.
  defp core_or_whole(core, raw) do
    case text(core) do
      "" -> text(raw)
      stripped -> stripped
    end
  end

  @doc """
  Every artist named by a track, normalized, as a set.

  A set rather than a list because credit *order* is not agreed between
  services — one leads with the headliner, another alphabetizes — and comparing
  ordered lists would make that disagreement look like a mismatch.

      iex> alias OnePlaylist.Matching.Normalize
      iex> Normalize.artists(["JAY-Z", "Alicia Keys"]) |> MapSet.to_list() |> Enum.sort()
      ["alicia keys", "jay z"]

  **No empty name is ever in the set**, which catches a false *positive* rather
  than a missed match and is the more dangerous direction. A track whose artist
  credit is punctuation — `"???"`, `"-"`, a stray separator — normalizes to `""`,
  and two such tracks then score a perfect artist match against each other while
  naming nobody at all.
  """
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
    # No `Enum.reject(&(&1 == ""))` after this, and its absence is deliberate:
    # the `trim: true` below already drops the empty that a credit like "???"
    # normalizes to. Adding one would guard `no_empty_names` twice over, leaving
    # it falsifiable only by a double mutation — which is another way of saying
    # the contract could no longer earn its place. Without it, losing that
    # `trim: true` is caught.
    |> Enum.flat_map(&String.split(&1, @word_separators, trim: true))
    |> MapSet.new()
  end

  @doc """
  An album title without the annotation a store added to it.

  A stored album is routinely the catalogue's title plus something the source
  put after a delimiter — *Lost Dogs: Rarities and B Sides* against *Lost Dogs*,
  *Touring Band 2000 - Instrumentals* against *Touring Band 2000*, *Vitalogy
  [2011 Reissue]* against *Vitalogy*. Compared whole, those disagree; compared
  by this, they are one album.

  ## Why a delimiter and not a prefix

  The obvious rule — "one title is a prefix of the other" — is wrong, and
  measurably so. *Greatest Hits* is a prefix of *Greatest Hits Vol. 2* and they
  are two different records. A delimiter is what distinguishes an annotation
  from a distinguishing part of the name: an edition, a disc subtitle and a
  reissue marker are introduced by one, and a volume number is not.

  A **spaced hyphen is not one of the delimiters**, and that was measured rather
  than assumed. It is the "Artist - Album" separator at least as often as it is a
  subtitle marker, so stripping at it turned the store-invented bucket *Pearl Jam
  - Non-Album Tracks* into *Pearl Jam* — a real album, whose cover and identity a
  pseudo-album then adopted. The cost is that *Touring Band 2000 - Instrumentals*
  is not recognised as *Touring Band 2000*; the alternative was a false identity,
  which is worse.

  Nothing is stripped when there is no delimiter, so this only ever loosens the
  cases it was written for.

      iex> alias OnePlaylist.Matching.Normalize
      iex> Normalize.album("Lost Dogs: Rarities and B Sides")
      "lost dogs"
      iex> Normalize.album("Greatest Hits Vol. 2")
      "greatest hits vol 2"
      iex> Normalize.album("Pearl Jam - Non-Album Tracks")
      "pearl jam non album tracks"
      iex> Normalize.album("Live: 05-03-03 - State College, Pennsylvania")
      "live 05 03 03 state college pennsylvania"
  """
  @doc """
  Whether two album titles name one album.

  `album/1` equality, plus one asymmetric case it cannot reach: **one title is
  exactly the other's core**, the other carrying a subtitle after a delimiter.
  *Crucible* and *Crucible - The Songs of Hunters & Collectors* are one album.
  *Greatest Hits - Volume One* and *Greatest Hits - Volume Two* are not, because
  neither one *is* the other's core — which is exactly what the symmetric
  version of this rule would get wrong.

  That asymmetry is the whole of it, and it is why this is not the spaced-hyphen
  normalization that was measured and rejected. Stripping at a spaced hyphen on
  *both* sides made *Pearl Jam - Non-Album Tracks* into *Pearl Jam*, so a
  store-invented bucket adopted a real record's identity. Here the hyphen only
  ever licenses a comparison against a title that is *already* just "Pearl Jam",
  which is a much narrower claim.

  Measured against `dev/corpus/album_cases.json`: **80.7% accuracy and 65.1%
  recall against `album/1`'s 79.5% and 62.3%**, recovering seven true pairs for
  one additional false positive.

  It was rejected once on that arithmetic, because
  `dev/corpus/replay_album_cases.exs` states that a false negative is never
  worth trading a false positive for. What changed is a real case rather than an
  argument. MusicBrainz files *Crucible* and *Crucible: The Songs of Hunters &
  Collectors* as releases of the **same recording**, so titles of exactly this
  shape do name one album — and the corpus, labelled by release *groups*, counts
  some of them as different. Its false-positive column already carries noise of
  precisely this kind: three of the six it reports for `album/1` are duplicate
  release groups rather than mistakes.

  ## The artist guard, and why it is not optional

  Pass `artists:` and a head that *is* one of them will not license a match.
  That is the difference between a subtitle marker and the "Artist - Album"
  separator, and without it this rule reproduces the exact failure the symmetric
  version was rejected for.

  Not theory. Shipped without the guard, it identified a library recording
  stored as *Immortality* on the store-invented bucket **"Pearl Jam - Non-Album
  Tracks"** against a MusicBrainz release titled **"Pearl Jam"** — the band's
  self-titled album, which has no such track. The asymmetry was supposed to make
  that impossible by requiring the other side to be exactly the core; the
  catalogue simply *has* a release with that name.

  The guard costs nothing measurable: `dev/corpus/album_cases.json` scores
  80.7% and 65.1% either way. It is free because a head that equals the credit
  is almost never a real album core, and where it is — a self-titled record with
  an edition suffix — the loss is a cover, not a wrong identity.

  The remaining cost is real and worth naming: *100th Window - The Remixes* is
  now called the same album as *100th Window*, which it is not. A remix edition
  is a distinct record, and this rule cannot see that where the subtitle happens
  to be the only thing distinguishing it.

      iex> alias OnePlaylist.Matching.Normalize
      iex> Normalize.same_album?("Crucible", "Crucible - The Songs of Hunters & Collectors")
      true
      iex> Normalize.same_album?("Lost Dogs", "Lost Dogs: Rarities and B Sides")
      true
      iex> Normalize.same_album?("Greatest Hits", "Greatest Hits Vol. 2")
      false
      iex> Normalize.same_album?("Greatest Hits - Volume One", "Greatest Hits - Volume Two")
      false
      iex> Normalize.same_album?("Pearl Jam - Non-Album Tracks", "Pearl Jam", artists: ["Pearl Jam"])
      false
  """
  @spec same_album?(String.t() | nil, String.t() | nil, keyword()) :: boolean()
  def same_album?(left, right, opts \\ []) do
    left_core = album(left)
    right_core = album(right)

    names = opts |> Keyword.get(:artists, []) |> List.wrap() |> Enum.map(&text/1)

    left_core == right_core or subtitled?(right, left_core, names) or
      subtitled?(left, right_core, names)
  end

  # True when `title` is `core` followed by a subtitle. The spaced hyphen is a
  # delimiter *here* and not in `album/1`, and the asymmetry is what makes that
  # safe: nothing is stripped unless the other side is already the bare core.
  defp subtitled?(title, core, artist_names) do
    case String.split(to_string(title), ~r/\s+[-–—:]\s+/u, parts: 2) do
      [head, _subtitle] ->
        stripped = album(head)

        stripped != "" and stripped == core and core != "" and core not in artist_names

      _none ->
        false
    end
  end

  @spec album(String.t() | nil) :: String.t()
  def album(nil), do: ""

  def album(title) when is_binary(title) do
    title
    |> strip_trailing_brackets()
    |> strip_subtitle()
    |> text()
    |> case do
      "" -> text(title)
      core -> core
    end
  end

  # Repeatedly, because an album can carry more than one: "2000.08.24 - Jones
  # Beach, New York (NYC) (Live)". Only *trailing* ones — a bracket in the middle
  # is part of the name.
  defp strip_trailing_brackets(title) do
    stripped = String.replace(title, ~r/\s*[(\[][^()\[\]]*[)\]]\s*$/u, "")

    if stripped == title, do: title, else: strip_trailing_brackets(stripped)
  end

  # A colon subtitle, and **only when more than one word precedes it**. A single
  # word before a colon is a category prefix rather than an album name — "Live:
  # 05-03-03 - State College, Pennsylvania" reduces to "Live", which matches
  # every live record ever made. Two or more is a name with a subtitle after it:
  # "Lost Dogs: Rarities and B Sides".
  defp strip_subtitle(title) do
    case String.split(title, ~r/\s*:\s*/u, parts: 2) do
      [core, _subtitle] ->
        if length(String.split(core, ~r/\s+/u, trim: true)) > 1, do: core, else: title

      _none ->
        title
    end
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

  **No name is lost**: every name goes to exactly one side, and the two sides
  together are exactly what `artists/1` reports. The separator lists have to stay
  a partition of one another and nothing else checks that — adding a marker to
  one and forgetting the other silently drops a collaborator, which is the very
  bug this function exists to fix wearing other clothes.
  """
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
