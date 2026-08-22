defmodule OnePlaylist.Matching.Strategy.Fuzzy do
  @moduledoc """
  Rung 5: approximate, and honest about it.

  The last rung before giving up. Nothing here is exact: titles are compared
  with Jaro-Winkler, artists with set overlap, and everything is averaged. It
  scores in the bottom band, so a fuzzy match never outranks a text one however
  well it scores.

  This rung is where the confidence threshold earns its keep. Its output is
  meant to be *reviewed*, not trusted — the middle of this band is exactly the
  material `docs/reference/domain.md` describes putting in front of the user
  rather than transferring silently.

  ## It still vetoes

  The discriminating-tag veto from `OnePlaylist.Matching.Strategy.Text` applies
  here unchanged, and matters more. A karaoke version has a high fuzzy
  similarity to the original by construction — same title, same credited
  writer, similar length. Approximation is what this rung is for; approximating
  across a `(Karaoke Version)` marker is not.

  ## Why it does not refuse to answer

  It scores every candidate it is given, including terrible ones, rather than
  returning `nil` below some floor. The threshold in `OnePlaylist.Matching`
  decides what is acceptable, and the scores it rejects are not wasted: they
  become the "candidates considered" in
  `OnePlaylist.Matching.TrackNotMatched`, which is how a user finds out *why* a
  track did not transfer instead of just that it did not.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Matching.Similarity
  alias OnePlaylist.Music.Track

  @impl true
  def strategy, do: :fuzzy

  @impl true
  def score(%Track{} = source, %Track{} = candidate) do
    signals = Signals.compare(source, candidate)

    with false <- signals.discriminating_conflict,
         raw when is_float(raw) <- combine(signals) do
      {raw, evidence(signals)}
    else
      _no_opinion -> nil
    end
  end

  # Title carries the most weight because it is the field most likely to be
  # present and the one a wrong match most often gets wrong. Duration is
  # weighted above album because a cover or a live take betrays itself in
  # seconds far more reliably than in which compilation it appears on.
  defp combine(signals) do
    Similarity.weighted_mean([
      {signals.title, 5},
      {signals.artists, 3},
      {signals.duration, 2},
      {signals.album, 1},
      {editorial_penalty(signals), 1}
    ])
  end

  defp editorial_penalty(%{editorial_conflict: true}), do: 0.0
  defp editorial_penalty(_signals), do: nil

  defp evidence(signals) do
    [
      title: signals.title,
      artists: signals.artists,
      duration: signals.duration,
      album: signals.album
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
