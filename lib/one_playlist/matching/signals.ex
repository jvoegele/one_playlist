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

  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.Matching.Similarity
  alias OnePlaylist.Music.Track

  @type t :: %{
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

  @doc "Compares two tracks across every signal this module knows about."
  @spec compare(Track.t(), Track.t()) :: t()
  def compare(%Track{} = source, %Track{} = candidate) do
    left = Normalize.title(source.title, source.version)
    right = Normalize.title(candidate.title, candidate.version)

    left_artists = artist_set(source, left)
    right_artists = artist_set(candidate, right)

    left_words = artist_words(left_artists)
    right_words = artist_words(right_artists)

    %{
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
  Normalizes a UPC or EAN for comparison.

  Leading zeros are stripped because the same release is a 12-digit UPC on one
  service and the same number zero-padded to a 13-digit EAN on another — TIDAL
  reports `"00602547670052"` for a barcode catalogues elsewhere print as
  `"602547670052"`. Comparing them as written makes every cross-service UPC
  match fail, silently and completely.
  """
  @spec normalize_barcode(String.t() | nil) :: String.t() | nil
  def normalize_barcode(nil), do: nil

  def normalize_barcode(value) when is_binary(value) do
    case value |> String.replace(~r/\D/, "") |> String.trim_leading("0") do
      "" -> nil
      digits -> digits
    end
  end

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
    with left when is_binary(left) <- normalize_barcode(left),
         right when is_binary(right) <- normalize_barcode(right) do
      left == right
    else
      _absent -> nil
    end
  end

  # Only a *disagreement* counts. Two tracks that both carry `:live` agree, and
  # two that carry none agree; one carrying `:live` alone does not.
  defp conflict?(left, right), do: not MapSet.equal?(left, right)
end
