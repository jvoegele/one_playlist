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

    # `duration_conflict` gates this rung specifically, and it is the fix for the
    # only genuine errors the cross-service measurement found.
    #
    # Kraftwerk's "Neonlicht" is 535 seconds; TIDAL lists a "Neonlicht" of 344.
    # Same title, same artist, same album, and neither catalogue labels either
    # one — so there is no version marker for `vetoed?` to fire on, and the
    # title gate below passes. The duration signal *did* say `0.0`, and the
    # weighted mean then buried it: this rung's band floor is `0.80`, above the
    # default `:medium` threshold, so every match it returns is confident by
    # construction. A rung that cannot express doubt must decline instead.
    #
    # Declining hands the candidate to `Fuzzy`, whose band is `0.0`–`0.79` and
    # which can score it low rather than discard it. Measured over the
    # hundred-track MusicBrainz corpus: wrong matches fell from 4 to 1, with no
    # correct match lost. See `docs/reference/domain.md`.
    cond do
      not gated_in?(signals) -> nil
      signals.credit_match == :unrelated -> nil
      # A credit that differs by a name does not decide the match — it raises
      # the bar. `Neil Young & Pearl Jam` against `Neil Young` and
      # `Neil Young & Crazy Horse` against `Neil Young` are indistinguishable
      # from the strings alone: identical artist similarity, one a
      # collaboration and one a backing band. Refusing both loses real matches;
      # accepting both put a Neil Young solo recording in a Pearl Jam playlist.
      #
      # So an ambiguous credit is allowed to match *when something else
      # confirms it*, and declines when nothing does. That is not a compromise
      # between the two errors, it is the honest reading: with a title, a
      # partial credit and no other agreeing field, there is no evidence either
      # way, and a rung that cannot express doubt must decline.
      signals.credit_match == :contained and not corroborated?(signals) -> nil
      true -> {corroboration(signals), evidence(signals)}
    end
  end

  defp gated_in?(signals) do
    signals.title_exact and not Signals.vetoed?(signals) and not signals.duration_conflict
  end

  # One field that both sides carry and that agrees strongly. Not a weighted
  # mean: this asks whether there is *any* independent confirmation, and a
  # single strong agreement is exactly that. `@uncorroborated` covers the
  # opposite case — no evidence — and is only reachable when the credits already
  # agree.
  @confirmation 0.9

  defp corroborated?(signals) do
    signals.upc_agrees == true or
      confirms?(signals.duration) or confirms?(signals.album)
  end

  defp confirms?(signal), do: is_number(signal) and signal >= @confirmation

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
