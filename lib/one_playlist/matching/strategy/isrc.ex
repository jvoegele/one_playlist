defmodule OnePlaylist.Matching.Strategy.Isrc do
  @moduledoc """
  Rung 1: the same recording, by identifier.

  An ISRC identifies a *recording*, globally and uniquely. Two tracks sharing
  one are the same performance, mastered from the same source — not a good
  guess, not a confident opinion, the same thing. This rung is the only one
  besides `OnePlaylist.Matching.Strategy.UpcPosition` allowed to score `1.0`.

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

  Delegates to `OnePlaylist.Music.Isrc.normalize/1`, which is where it lives
  now. It moved because this module is about *comparing* two tracks, and a
  lookup needs the same canonical form — `Tidal.candidates/3` sends an ISRC to
  the provider, and normalising only at comparison time let a lower-case
  identifier reach TIDAL and be rejected. See that module.

      iex> alias OnePlaylist.Matching.Strategy.Isrc
      iex> Isrc.normalize("gb-aye-06-01477")
      "GBAYE0601477"
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  defdelegate normalize(value), to: OnePlaylist.Music.Isrc
end
