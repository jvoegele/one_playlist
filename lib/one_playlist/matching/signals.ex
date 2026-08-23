defmodule OnePlaylist.Matching.Signals do
  @moduledoc """
  Every comparison between two tracks, computed once.

  The text and fuzzy rungs ask the same questions and disagree only about how
  strictly to read the answers, so the questions are asked here and each rung
  interprets the result. That also means a signal is defined in exactly one
  place: if "do these artists agree?" is wrong, it is wrong in one function.

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
            artists_agree: false,
            album: nil,
            duration: nil,
            upc_agrees: nil,
            discriminating_conflict: false,
            editorial_conflict: false

  @typedoc "Every comparison between two tracks, computed once."
  @type t :: %__MODULE__{
          title: float() | nil,
          title_exact: boolean(),
          artists: float() | nil,
          artists_agree: boolean(),
          album: float() | nil,
          duration: float() | nil,
          upc_agrees: boolean() | nil,
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

    left_artists = artist_set(source, left)
    right_artists = artist_set(candidate, right)

    left_words = artist_words(left_artists)
    right_words = artist_words(right_artists)

    %__MODULE__{
      title: title_similarity(left.title, right.title),
      title_exact: left.title != "" and left.title == right.title,
      artists: artist_similarity(left_artists, right_artists, left_words, right_words),
      artists_agree:
        artists_agree?(left_artists, right_artists) or
          words_agree?(left_words, right_words),
      album: album_similarity(source.album, candidate.album),
      duration:
        Similarity.duration_proximity(source.duration_seconds, candidate.duration_seconds),
      upc_agrees: upc_agrees?(source.album_upc, candidate.album_upc),
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

  Named rather than left as a field read because it appeared in three places
  spelled three slightly different ways, and because `discriminating_conflict`
  describes the data while `vetoed?` describes what to do about it.

      iex> alias OnePlaylist.Matching.Signals
      iex> Signals.vetoed?(%Signals{discriminating_conflict: true})
      true
      iex> Signals.vetoed?(%Signals{title: 1.0})
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

  This was written out identically as a private function in both
  `OnePlaylist.Matching.Strategy.Text` and
  `OnePlaylist.Matching.Strategy.Fuzzy` — one rule, two copies, and no test that
  would have noticed them drifting apart.

      iex> alias OnePlaylist.Matching.Signals
      iex> Signals.editorial_penalty(%Signals{editorial_conflict: true})
      0.0
      iex> Signals.editorial_penalty(%Signals{editorial_conflict: false})
      nil
  """
  @spec editorial_penalty(t()) :: float() | nil
  def editorial_penalty(%__MODULE__{editorial_conflict: true}), do: 0.0
  def editorial_penalty(%__MODULE__{}), do: nil

  # A title's own artists, plus anyone the title credited as a guest.
  defp artist_set(%Track{} = track, parsed_title) do
    track.artists
    |> Normalize.artists()
    |> MapSet.union(MapSet.new(parsed_title.featuring))
  end

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
  # so is "Street Band Bruce". `artists_agree?/2` is where containment belongs,
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

  # Containment rather than equality: services disagree about how many artists
  # to credit far more often than they disagree about who the artists are, so
  # requiring the same set would reject true matches wholesale. What must not
  # happen is a *disjoint* credit — that is a different recording.
  defp artists_agree?(left, right) do
    cond do
      MapSet.size(left) == 0 or MapSet.size(right) == 0 -> false
      MapSet.size(left) <= MapSet.size(right) -> MapSet.subset?(left, right)
      true -> MapSet.subset?(right, left)
    end
  end

  defp album_similarity(nil, _right), do: nil
  defp album_similarity(_left, nil), do: nil

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
