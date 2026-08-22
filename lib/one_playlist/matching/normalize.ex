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

  # Splits an artist credit into individual names. `feat` is included because a
  # provider may put the whole credit in one string.
  @artist_separators ~r/\s*(?:,|&|\/|\+|\bx\b|\band\b|\bfeat\b|\bft\b|\bfeaturing\b|\bwith\b|\bvs\b)\s*/u

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
  @spec artists([String.t()] | String.t() | nil) :: MapSet.t(String.t())
  def artists(nil), do: MapSet.new()
  def artists(value) when is_binary(value), do: artists([value])

  def artists(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, @artist_separators, trim: true))
    |> Enum.map(&text/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  @doc """
  The distinct words of a normalized string, as a set.

  Used for token-set similarity, which is what makes word order and duplicated
  words stop mattering.
  """
  @spec tokens(String.t() | nil) :: MapSet.t(String.t())
  def tokens(value) do
    value |> text() |> String.split(" ", trim: true) |> MapSet.new()
  end

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
