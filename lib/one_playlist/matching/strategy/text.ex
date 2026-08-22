defmodule OnePlaylist.Matching.Strategy.Text do
  @moduledoc """
  Rung 3: identical after normalization.

  Title and artists must match *exactly* once accents, case, punctuation,
  featured-artist placement and version markers have been normalized away. That
  is a strict test by design — this rung's job is to be right, and the fuzzy
  rung below it is where approximation is allowed.

  ## The veto

  A disagreement about a discriminating tag — `:live`, `:karaoke`,
  `:instrumental`, `:acoustic`, `:remix`, `:demo`, `:cover` — rejects the
  candidate outright, whatever else agrees.

  This is the single most valuable rule in the module. "Hey Jude" and "Hey Jude
  (Karaoke Version)" have the same normalized title, the same artist, and often
  a similar duration. Every text signal says yes. It is still the wrong track,
  and shipping it is worse than shipping nothing, because the user is never
  told.

  ## What the score varies with

  Exact title and artist is the *entry* requirement, so it cannot also be what
  distinguishes a good match here from a mediocre one. The score comes from
  what else corroborates: duration, album title, release barcode, and whether
  the editorial tags agree. A match with nothing corroborating still scores
  respectably, but not at the top of the band — which is correct, because two
  different recordings really can carry identical text.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Matching.Similarity
  alias OnePlaylist.Music.Track

  # Text agreement alone, with nothing to corroborate it and nothing to
  # contradict it. Deliberately mid-band: unsupported text is a real match and
  # not a confident one.
  @uncorroborated 0.5

  @impl true
  def strategy, do: :text

  @impl true
  def score(%Track{} = source, %Track{} = candidate) do
    signals = Signals.compare(source, candidate)

    if signals.title_exact and signals.artists_agree and not Signals.vetoed?(signals) do
      {corroboration(signals), evidence(signals)}
    end
  end

  defp corroboration(signals) do
    [
      {signals.duration, 3},
      {signals.album, 2},
      {barcode_signal(signals), 2},
      {Signals.editorial_penalty(signals), 2}
    ]
    |> Similarity.weighted_mean()
    |> Kernel.||(@uncorroborated)
  end

  defp barcode_signal(%{upc_agrees: nil}), do: nil
  defp barcode_signal(%{upc_agrees: true}), do: 1.0

  # Different releases is weak evidence against, not proof: the same recording
  # appears on a single, an album and three compilations.
  defp barcode_signal(%{upc_agrees: false}), do: 0.4

  defp evidence(signals) do
    [duration: signals.duration, album: signals.album, upc_agrees: signals.upc_agrees]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.put(:title, :exact)
  end
end
