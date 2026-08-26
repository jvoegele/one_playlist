defmodule OnePlaylist.Matching.Strategy.Isrc do
  @moduledoc """
  Rung 1: the same recording, by identifier.

  An ISRC identifies a *recording*, globally and uniquely. Two tracks sharing
  one are the same performance, mastered from the same source — not a good
  guess, not a confident opinion, the same thing. That is why this rung scores
  `1.0`; the only other rung allowed to is
  `OnePlaylist.Matching.Strategy.UpcPosition`, which is also an identifier
  rather than an opinion.

  It is also the rung that matters most in practice, because the services this
  product transfers between all expose ISRCs on most of their catalogue. The
  rest of the ladder exists for the remainder: local files, some regional
  entries, and recordings whose ISRC differs per territory.

  ## What an ISRC match does not promise

  That the *user* wants that specific recording, and that the recording is
  playable where they are. A track can match exactly and still be unavailable
  in their market. That is a separate problem, handled at transfer time.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Music.Track

  @impl true
  def strategy, do: :isrc

  # The moduledoc's first paragraph, checked. Over the *normalized* pair, because
  # that is what the rung claims — and the `nil` conjunct is not decoration:
  # `normalize/1` answers `nil` for a value that is not an ISRC at all, without
  # which two pieces of junk compare equal and match.
  #
  # Proven by mutation: dropping the equality test fires it.
  @post_strengthen only_on_equal_identifiers:
                     not is_nil(result)
                     ~> (not is_nil(normalize(source.isrc)) and
                           normalize(source.isrc) == normalize(candidate.isrc))
  @impl true
  def score(source, candidate)

  def score(%Track{isrc: source_isrc}, %Track{isrc: candidate_isrc})
      when is_binary(source_isrc) and is_binary(candidate_isrc) do
    normalized = normalize(source_isrc)

    if normalized != nil and normalized == normalize(candidate_isrc) do
      {1.0, [isrc: normalized]}
    end
  end

  def score(_source, _candidate), do: nil

  @doc """
  Canonical form of an ISRC.

  Delegates to `OnePlaylist.Music.Isrc.normalize/1`, which is where the rule
  lives: a *lookup* needs the same canonical form a comparison does, and this
  module is only about the comparison. See that module for what happens
  otherwise.

      iex> alias OnePlaylist.Matching.Strategy.Isrc
      iex> Isrc.normalize("gb-aye-06-01477")
      "GBAYE0601477"
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  defdelegate normalize(value), to: OnePlaylist.Music.Isrc
end
