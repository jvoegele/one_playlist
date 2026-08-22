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
  Canonical form of an ISRC: twelve alphanumeric characters, upper case.

  The standard is `CC-XXX-YY-NNNNN` and services print it with and without the
  hyphens, so comparing the raw strings makes the same recording look like two.
  Anything that is not twelve characters after stripping is rejected rather
  than compared — a truncated or malformed identifier that happens to equal
  another malformed one is not evidence of anything.

      iex> alias OnePlaylist.Matching.Strategy.Isrc
      iex> Isrc.normalize("gb-aye-06-01477")
      "GBAYE0601477"
      iex> Isrc.normalize("nonsense")
      nil
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(value) when is_binary(value) do
    normalized = value |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.upcase()

    if String.length(normalized) == 12, do: normalized
  end
end
