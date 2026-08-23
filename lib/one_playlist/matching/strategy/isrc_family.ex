defmodule OnePlaylist.Matching.Strategy.IsrcFamily do
  @moduledoc """
  Rung 1b: the same recording, by an identifier it is *also* known by.

  An ISRC identifies a recording **as issued on a particular release**, so the
  same master carries a different code on every reissue. Roon exports Eddie
  Vedder's *Setting Forth* as `USJY50700001`, the 2007 soundtrack; TIDAL holds
  `USJY51700100`, the 2017 reissue. The codes disagree and the recording is the
  same one.

  `OnePlaylist.MusicBrainz` answers which codes name one recording, and
  `Track.isrc_family` carries the answer. This rung matches a candidate whose
  identifier is in that set.

  ## Why it is a rung of its own rather than a looser `Isrc`

  Two reasons, and the second is the one that matters.

  The certainty is different in kind. `Strategy.Isrc` needs no third party: two
  identical identifiers are the same recording by definition. Here the claim
  rests on MusicBrainz's judgment, which is edited by volunteers and can be
  wrong. Scoring `0.99` under `:linked_isrc` rather than `1.0` under
  `:exact_isrc` puts that difference in the report, where a person reviewing a
  transfer can see where the confidence came from.

  And it lets this rung be **more careful than the one above it**. An identifier
  match deliberately ignores the version veto — a provider mislabelling a
  version on a correctly-ISRC'd track must not break the match. That trust is
  earned by the identifier being the same; it is not earned by a third party
  saying two identifiers are equivalent. So this rung keeps the duration check,
  and a candidate whose length disagrees is refused however good the linkage
  looks.

  ## What it costs

  Nothing, at match time. The family is looked up once per track that failed the
  identifier rung, cached in two tiers, and the candidates are the ones already
  in hand — no second provider call. See `OnePlaylist.MusicBrainz`.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Matching.Similarity
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track

  # The band this rung scores inside. See `OnePlaylist.Matching.Confidence`.
  #
  # A range rather than a point because one recording is commonly linked to
  # several releases, and all of them are in the family. The identifier says
  # *which recording*; it says nothing about which copy of it to take, and
  # picking arbitrarily produced a 2Pac track from a compilation when the
  # source's own album was on offer.
  @floor 0.95
  @ceiling 0.99

  # Nothing to go on either way. Mid-band, so a candidate with no album and no
  # duration neither beats nor loses to one that agrees.
  @unknown 0.5

  # `Similarity.duration_proximity/2` answers `0.0` for a disagreement it
  # considers real, which is the same signal `Signals.duration_conflict` is
  # built from. Reused rather than re-derived so the two cannot drift.
  @conflict 0.0

  @impl true
  def strategy, do: :isrc_family

  @impl true
  def score(source, candidate)

  def score(
        %Track{isrc_family: [_ | _] = family} = source,
        %Track{isrc: candidate_isrc} = candidate
      )
      when is_binary(candidate_isrc) do
    with linked when not is_nil(linked) <- Isrc.normalize(candidate_isrc),
         true <- linked in family,
         # Not the source's own identifier: that is `Strategy.Isrc`'s answer,
         # and it scores higher. Letting this rung answer it too would report a
         # weaker confidence for a stronger fact, depending only on which rung
         # ran first.
         false <- linked == Isrc.normalize(source.isrc),
         false <- lengths_disagree?(source, candidate) do
      {placement(source, candidate), [isrc_family: linked, source_isrc: source.isrc]}
    else
      _no -> nil
    end
  end

  def score(_source, _candidate), do: nil

  # Where in the band. Only for choosing between releases of one recording —
  # every candidate that reaches here is already the right *recording*, so this
  # is not evidence about whether to match, only about which copy.
  defp placement(source, candidate) do
    signals = Signals.compare(source, candidate)

    corroboration =
      [signals.album, signals.duration]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> @unknown
        values -> Enum.sum(values) / length(values)
      end

    @floor + (@ceiling - @floor) * corroboration
  end

  # Absent durations are not a disagreement. A CSV import carries none at all,
  # and refusing every one of those would give back exactly the tracks this rung
  # exists to recover.
  defp lengths_disagree?(%Track{duration_seconds: left}, %Track{duration_seconds: right})
       when is_integer(left) and is_integer(right),
       do: Similarity.duration_proximity(left, right) == @conflict

  defp lengths_disagree?(_source, _candidate), do: false
end
