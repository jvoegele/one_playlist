defmodule OnePlaylist.MusicFixtures do
  @moduledoc """
  Track fixtures for the matching tests.

  `track/1` fills in a plausible, matchable track so a test can state only the
  field it is about. That matters more here than convenience: a matching test
  that says `track(title: "Yesterday (Live)")` reads as "the same track, but
  live", which is exactly the comparison being made.

  It also guards against a failure this project has already hit twice — a
  contract surviving a mutation because every fixture happened to omit the case
  it describes. Defaults that are *present and sensible* mean a test has to opt
  out of a field deliberately rather than forget it.
  """

  alias OnePlaylist.Music.Track

  @doc "A track, with matchable defaults for anything not given."
  @spec track(keyword()) :: Track.t()
  def track(overrides \\ []) do
    defaults = [
      provider: :tidal,
      provider_id: "t#{System.unique_integer([:positive])}",
      isrc: nil,
      title: "Yesterday",
      artists: ["The Beatles"],
      album: "Help!",
      duration_seconds: 125,
      explicit: false
    ]

    struct!(Track, Keyword.merge(defaults, overrides))
  end

  @doc """
  A source track and a candidate that differs only as described.

  Returns `{source, candidate}`.
  """
  @spec pair(keyword(), keyword()) :: {Track.t(), Track.t()}
  def pair(source_overrides \\ [], candidate_overrides \\ []) do
    {track(source_overrides), track(candidate_overrides)}
  end
end
