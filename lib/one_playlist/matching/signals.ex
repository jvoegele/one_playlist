defmodule OnePlaylist.Matching.Signals do
  @moduledoc """
  Every comparison between two tracks, computed once.

  The text and fuzzy rungs ask the same questions and disagree only about how
  strictly to read the answers, so the questions are asked here and each rung
  interprets the result. That also means a signal is defined in exactly one
  place: if "do these artists agree?" is wrong, it is wrong in one function.

  ## A length disagreement is a conflict, not a weak signal

  `duration` carries the proximity score; `duration_conflict` carries the
  separate fact that the two lengths are far enough apart for
  `Similarity.duration_proximity/2` to have nothing left to say.

  The distinction already existed in that function's return — `nil` for "one of
  them is missing" against `0.0` for "these are far apart" — and was being
  thrown away by the weighted mean, which treats `0.0` as a poor score rather
  than as contrary evidence. That is what let a text match survive a
  191-second disagreement at `:medium` confidence; see the cross-service
  measurement in `docs/reference/domain.md`.

  ## Featured artists are moved before comparing

  `Normalize.title/2` pulls `(feat. X)` out of a title and returns it as an
  artist. That happens *before* the comparison, so a service that credits the
  guest in the title and one that credits them in the artist list produce the
  same two sets — which is the single most common reason a true match fails on
  text.
  """

  use Bond

  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.Matching.Similarity
  alias OnePlaylist.Music.Barcode
  alias OnePlaylist.Music.Track

  # Every default is the "nothing to say" value, and every one of them satisfies
  # the invariant — a comparison that could not be made is `nil`, not a zero.
  # (`OnePlaylist.Providers.Tokens` is the opposite case, and its moduledoc says
  # why a struct sometimes cannot honour Meyer's base-case rule.)
  defstruct title: nil,
            title_exact: false,
            artists: nil,
            credit_match: :unrelated,
            album: nil,
            duration: nil,
            upc_agrees: nil,
            duration_conflict: false,
            discriminating_conflict: false,
            editorial_conflict: false

  @typedoc "Every comparison between two tracks, computed once."
  @type t :: %__MODULE__{
          title: float() | nil,
          title_exact: boolean(),
          artists: float() | nil,
          credit_match: :same | :contained | :unrelated,
          album: float() | nil,
          duration: float() | nil,
          upc_agrees: boolean() | nil,
          duration_conflict: boolean(),
          discriminating_conflict: boolean(),
          editorial_conflict: boolean()
        }

  # A similarity outside 0..1 is the textbook silently-poisonous value: it is not
  # a type error, nothing raises, and it goes straight into the weighted mean
  # that both scoring rungs use. A single 1.5 drags a non-match over the
  # confidence threshold and a transfer adds the wrong recording — reported as a
  # match, with a plausible-looking score.
  #
  # What this adds over `Similarity`'s own `in_unit_interval` postconditions is
  # worth being exact about, because for a value `compare/2` builds it really is
  # implied by them: every field here comes from a contracted `Similarity`
  # function, so the *exit* check restates what those already promise.
  #
  # The **entry** check is the part that earns its place. It guards values this
  # module did not build:
  #
  #   * a `%{signals | duration: ...}` update — the natural way a new rung will
  #     adjust a signal, and a path through no contracted function at all;
  #   * a hand-built `%Signals{}` in a fixture, which is how a test comes to
  #     assert against a score the engine could never produce;
  #   * a future signal computed inline rather than by `Similarity`, which the
  #     existing postconditions cannot see by construction.
  #
  # `nil` is explicitly allowed: it means "these could not be compared", which is
  # different from "they are not similar" and is what stops an absent album
  # scoring as a mismatch.
  @invariant similarities_are_proportions:
               forall(
                 score <- [subject.title, subject.artists, subject.album, subject.duration],
                 is_nil(score) or (is_float(score) and score >= 0.0 and score <= 1.0)
               )

  @doc "Compares two tracks across every signal this module knows about."
  @spec compare(Track.t(), Track.t()) :: t()
  def compare(%Track{} = source, %Track{} = candidate) do
    left = Normalize.title(source.title, source.version)
    right = Normalize.title(candidate.title, candidate.version)

    left_credits = credits(source, left)
    right_credits = credits(candidate, right)

    left_artists = all_names(left_credits)
    right_artists = all_names(right_credits)

    left_words = artist_words(left_artists)
    right_words = artist_words(right_artists)

    %__MODULE__{
      title: title_similarity(left.title, right.title),
      title_exact: left.title != "" and left.title == right.title,
      artists: artist_similarity(left_artists, right_artists, left_words, right_words),
      credit_match: credit_match(left_credits, right_credits, left_words, right_words),
      album: album_similarity(source.album, candidate.album),
      duration:
        Similarity.duration_proximity(source.duration_seconds, candidate.duration_seconds),
      upc_agrees: upc_agrees?(source.album_upc, candidate.album_upc),
      duration_conflict:
        Similarity.duration_proximity(source.duration_seconds, candidate.duration_seconds) == 0.0,
      discriminating_conflict:
        conflict?(Normalize.discriminating(left.tags), Normalize.discriminating(right.tags)),
      editorial_conflict:
        conflict?(Normalize.editorial(left.tags), Normalize.editorial(right.tags))
    }
  end

  @doc """
  Whether these two tracks are different *recordings* rather than a worse match.

  A discriminating conflict — one side live, karaoke, instrumental, acoustic, a
  remix, a demo or a cover and the other not — is a veto, not a penalty. No
  amount of title and artist agreement makes a karaoke version the studio
  recording, so both scoring rungs and `OnePlaylist.Matching`'s own
  postcondition ask this before they ask anything else.

  Named rather than left as a field read, because `discriminating_conflict`
  describes the data while `vetoed?` describes what to do about it — and
  because three call sites spelling one rule for themselves is three places for
  it to drift.

  > #### `duration_conflict` is deliberately not here {: .info}
  >
  > A length disagreement is evidence of a different performance too, and
  > stronger evidence than a label — but it stops the **text** rung only, in
  > `OnePlaylist.Matching.Strategy.Text`, rather than vetoing every rung.
  >
  > The asymmetry follows from the bands. The text rung's floor is `0.80`, above
  > the default `:medium` threshold, so *any* text match is inherently a
  > confident claim and there is no way for it to express doubt. The fuzzy rung
  > spans `0.0`–`0.79` and can say "probably not" numerically. So the rung that
  > cannot express degrees declines, and the rung that can scores it low — which
  > leaves the candidate visible to a caller who deliberately lowered the
  > threshold, instead of discarding it.

      iex> alias OnePlaylist.Matching.Signals
      iex> Signals.vetoed?(%Signals{discriminating_conflict: true})
      true
      iex> Signals.vetoed?(%Signals{duration_conflict: true, title: 1.0})
      false
  """
  @spec vetoed?(t()) :: boolean()
  def vetoed?(%__MODULE__{} = signals), do: signals.discriminating_conflict

  @doc """
  The score contribution of an editorial disagreement: `0.0`, or `nil`.

  Editorial tags — remaster, radio edit, extended, mono, single version — mark a
  different *release* of the same recording, so a disagreement is evidence
  against a match without being a veto.

  Only ever a penalty, never a reward. Agreement here is usually agreement that
  neither side labelled anything, and scoring that as similarity would reward
  silence: two tracks with no tags at all would earn a point for it. `nil` is
  how `Similarity.weighted_mean/1` is told to leave the term out entirely.

  Here rather than in each rung because `OnePlaylist.Matching.Strategy.Text`
  and `OnePlaylist.Matching.Strategy.Fuzzy` both want it, and one rule in two
  private copies is a rule nothing keeps in step.

      iex> alias OnePlaylist.Matching.Signals
      iex> Signals.editorial_penalty(%Signals{editorial_conflict: true})
      0.0
      iex> Signals.editorial_penalty(%Signals{editorial_conflict: false})
      nil
  """
  @spec editorial_penalty(t()) :: float() | nil
  def editorial_penalty(%__MODULE__{editorial_conflict: true}), do: 0.0
  def editorial_penalty(%__MODULE__{}), do: nil

  # Who made the recording, and who guested on it. A `(feat. X)` in the *title*
  # is a guest credit like any other, so it joins the featured side rather than
  # the set of names that has to agree.
  defp credits(%Track{} = track, parsed_title) do
    credits = Normalize.credits(track.artists)

    %{credits | featured: MapSet.union(credits.featured, MapSet.new(parsed_title.featuring))}
  end

  defp all_names(credits), do: MapSet.union(credits.primary, credits.featured)

  # Two untitled tracks are not similar, they are unknown. Without this,
  # `jaro_distance("", "")` returns 1.0 and every track missing a title matches
  # every other one perfectly.
  defp title_similarity("", _right), do: nil
  defp title_similarity(_left, ""), do: nil
  defp title_similarity(left, right), do: Similarity.jaro_winkler(left, right)

  # Every word across every credited artist, ignoring how the names were
  # divided up. This is the answer to the inverted-name convention: `"The
  # Beatles"` splits to one name and `"Beatles, The"` to two, so the name sets
  # disagree completely while the words are identical.
  #
  # A comma means "and another artist" often enough that splitting on it is
  # right, and means "surname first" often enough that it cannot be the only
  # comparison. Doing both costs nothing and neither convention is privileged.
  defp artist_words(names) do
    names
    |> Enum.flat_map(&String.split(&1, " ", trim: true))
    |> MapSet.new()
  end

  # Exact, because this comparison has already thrown away the structure that
  # made containment meaningful: once every credit is a bag of words, "Bruce
  # Springsteen" is contained in "Bruce Springsteen and the E Street Band" and
  # so is "Street Band Bruce". `credit_match/4` is where containment belongs,
  # and it decides that case on its own terms; this exists only to recognise the
  # same names divided up differently.
  defp words_agree?(left, right),
    do: MapSet.size(left) > 0 and MapSet.equal?(left, right)

  # Whichever reading of the credits is kinder, since a disagreement about
  # punctuation is not evidence about the recording.
  defp artist_similarity(left_names, right_names, left_words, right_words) do
    [
      Similarity.dice(left_names, right_names),
      Similarity.dice(left_words, right_words)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      scores -> Enum.max(scores)
    end
  end

  # How two credits relate, in three values rather than a yes/no.
  #
  # A boolean would have to decide, on its own, whether a one-name difference
  # meant "same recording, described differently" or "a different recording".
  # It cannot: `Neil Young & Pearl Jam` against `Neil Young` and
  # `Neil Young & Crazy Horse` against `Neil Young` are the same string problem,
  # scoring an identical 0.667 artist similarity. One is a collaboration and one
  # is a backing band, and no rule over those strings knows which.
  #
  # So this reports the *relationship* and lets `Strategy.Text` decide what
  # evidence it wants for each. `:same` needs none; `:contained` has to be
  # corroborated by something else; `:unrelated` is refused outright.
  #
  #   * `:same` — the primary credits are the same set, or the names scramble
  #     into each other ("Beatles, The" against "The Beatles").
  #   * `:contained` — one primary set is strictly inside the other. Either a
  #     credit one service spells out and another does not, or a collaboration
  #     matched to a solo take. Genuinely ambiguous, and treated as such.
  #   * `:unrelated` — disjoint, partially overlapping, or empty on either side.
  @spec credit_match(credits(), credits(), MapSet.t(), MapSet.t()) ::
          :same | :contained | :unrelated
  defp credit_match(left, right, left_words, right_words) do
    cond do
      MapSet.size(left.primary) == 0 or MapSet.size(right.primary) == 0 -> :unrelated
      same_act?(left, right, left_words, right_words) -> :same
      ambiguous?(left, right, left_words, right_words) -> :contained
      true -> :unrelated
    end
  end

  # The same names, or names that scramble into each other — "Beatles, The"
  # against "The Beatles". A backing band lands here too, because
  # `Normalize.credits/1` puts "and *the* Ys" beside the guests rather than
  # among the primaries.
  defp same_act?(left, right, left_words, right_words) do
    MapSet.equal?(left.primary, right.primary) or words_agree?(left_words, right_words)
  end

  # Credits that overlap without agreeing. Each of these is a *question*, not an
  # answer, and `Strategy.Text` makes them earn a match with corroboration:
  #
  #   * one set inside the other — a collaboration against a solo take, or a
  #     guest credit one service spells out;
  #   * sharing a name and differing on another — usually an artist renamed,
  #     Young Jeezy to Jeezy;
  #   * one credit's *words* inside the other's, with no shared name at all.
  #     An ensemble is commonly named by wrapping its leader — "The Jimi
  #     Hendrix Experience" around "Jimi Hendrix", "The Dave Brubeck Quartet"
  #     around "Dave Brubeck" — with no conjunction for the backing-band rule
  #     to find and each side a single different string.
  defp ambiguous?(left, right, left_words, right_words) do
    MapSet.subset?(left.primary, right.primary) or
      MapSet.subset?(right.primary, left.primary) or
      not MapSet.disjoint?(left.primary, right.primary) or
      ensemble_of?(left_words, right_words)
  end

  # Two words at least. A single shared word is not an ensemble naming its
  # leader, it is a coincidence — and every one-word artist is already handled
  # by the name-level checks above.
  @ensemble_floor 2

  defp ensemble_of?(left, right) do
    smaller = if MapSet.size(left) <= MapSet.size(right), do: left, else: right
    larger = if smaller == left, do: right, else: left

    MapSet.size(smaller) >= @ensemble_floor and MapSet.subset?(smaller, larger)
  end

  @typep credits :: %{primary: MapSet.t(String.t()), featured: MapSet.t(String.t())}

  defp album_similarity(nil, _right), do: nil
  defp album_similarity(_left, nil), do: nil

  # Jaro-Winkler reads an album subtitle backwards — it rewards a shared prefix
  # and penalises length, so a *short wrong* suffix ("Greatest Hits **Vol. 2**")
  # scores `0.937` and corroborates, while a *long right* one ("Lost Dogs**:
  # Rarities and B Sides**") scores `0.860` and does not. Both measured against a
  # real library.
  #
  # That is a genuine flaw and treating `Normalize.album/1` equality as agreement
  # is **not** the fix. Measured against the twelve hand-labelled cases in
  # `dev/Unmatched PJ Favorites.csv`, it converted misses into *wrong answers*
  # rather than into correct ones: with a spaced hyphen among the delimiters, two
  # correct and two wrong; with only colons and brackets, none correct and one
  # wrong, against a baseline of zero wrong. Sixth negative result recorded in
  # `docs/reference/domain.md`.
  #
  # The album core *is* used, in `OnePlaylist.Library.Enrichment` — where a wrong
  # answer costs a cover rather than an identity, and the recording has already
  # been identified by other means.
  defp album_similarity(left, right) do
    Similarity.jaro_winkler(Normalize.text(left), Normalize.text(right))
  end

  defp upc_agrees?(left, right) do
    with left when is_binary(left) <- Barcode.normalize(left),
         right when is_binary(right) <- Barcode.normalize(right) do
      left == right
    else
      _absent -> nil
    end
  end

  # Only a *disagreement* counts. Two tracks that both carry `:live` agree, and
  # two that carry none agree; one carrying `:live` alone does not.
  defp conflict?(left, right), do: not MapSet.equal?(left, right)
end
