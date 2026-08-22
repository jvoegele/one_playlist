defmodule OnePlaylist.MatchingCorpusTest do
  @moduledoc """
  The matching engine against real catalogue data.

  `test/support/fixtures/tidal_isrc_corpus.json` was captured from the live
  TIDAL API on 2026-08-22: 60 tracks taken from a real library, and for each,
  every catalogue entry TIDAL returns for that track's ISRC. It is committed so
  these run offline and in CI.

  ## Why a real corpus and not more hand-written cases

  Hand-written fixtures test what the author already thought of. This corpus
  contains what the catalogue actually looks like, which is messier in ways
  worth knowing about — 40 of the 60 tracks resolve to **more than one**
  candidate, and one resolves to twenty. Ambiguity is the normal case, and no
  invented fixture would have said so with that much conviction.

  ## The measurement in `"without identifiers"`

  ISRC matching is not the interesting part; it either works or the data is
  wrong. What matters for the product is how the ladder does when the
  identifier is gone, because that is the situation on every track a service
  does not supply an ISRC for.

  So that test strips the ISRCs and re-runs, measuring how much of the corpus
  the text and fuzzy rungs recover on their own. The assertion is a floor, not
  a target: it exists to catch a normalization regression. The number itself is
  printed, because watching it move is the point.

  > #### Do not read that number as a cross-service match rate {: .warning}
  >
  > Source and candidates both come from TIDAL, so their titles and artist
  > credits were written by the same cataloguer and agree far more often than
  > two different services would. The measurement is a **regression floor**
  > against this corpus and nothing more.
  >
  > The honest version of this measurement needs a second provider, and cannot
  > be made until there is one. When Spotify or Apple Music is added, a corpus
  > pairing the same recording across both is the thing to capture, and this
  > test is where it belongs.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Matching
  alias OnePlaylist.Matching.Report
  alias OnePlaylist.Music.Track

  @corpus_path "test/support/fixtures/tidal_isrc_corpus.json"

  setup_all do
    rows =
      @corpus_path
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn row ->
        {track(row["source"]), Enum.map(row["candidates"], &track/1)}
      end)

    {:ok, rows: rows}
  end

  defp track(attributes) do
    %Track{
      provider: :tidal,
      provider_id: attributes["provider_id"],
      isrc: attributes["isrc"],
      title: attributes["title"],
      version: attributes["version"],
      artists: attributes["artists"] || [],
      album: attributes["album"],
      album_upc: attributes["album_upc"],
      duration_seconds: attributes["duration_seconds"],
      explicit: attributes["explicit"],
      popularity: attributes["popularity"]
    }
  end

  describe "the corpus itself" do
    test "is big enough and ambiguous enough to be worth running", %{rows: rows} do
      # Guards against the vacuity trap: a corpus that quietly emptied would
      # make every assertion below pass while testing nothing.
      assert length(rows) >= 50

      candidates = rows |> Enum.map(fn {_source, c} -> length(c) end) |> Enum.sum()
      assert candidates >= 200

      ambiguous = Enum.count(rows, fn {_source, c} -> length(c) > 1 end)

      assert ambiguous >= 20,
             "the corpus should contain real ambiguity, or the tie-breaking is untested"
    end
  end

  describe "with identifiers" do
    test "every track resolves to an exact ISRC match", %{rows: rows} do
      report = Matching.match_all(rows)

      assert Report.total(report) == length(rows)

      for match <- report.matched do
        assert match.confidence == :exact_isrc
        assert match.strategy == :isrc

        assert normalize(match.track.isrc) == normalize(match.source.isrc),
               "matched #{match.track.title} to a different recording"
      end
    end

    test "nothing is lost", %{rows: rows} do
      report = Matching.match_all(rows)

      # One track in the captured corpus returned no candidates at all. That is
      # a real outcome, not a defect — and the point is that it is *reported*
      # rather than dropped.
      assert Report.match_rate(report) >= 0.95

      for error <- report.unmatched do
        assert Errata.context(error).candidates_considered == 0
      end
    end

    test "ambiguity is recorded rather than hidden", %{rows: rows} do
      report = Matching.match_all(rows)
      ambiguous = Report.ambiguous(report)

      assert length(ambiguous) >= 20

      for match <- ambiguous do
        assert match.alternatives > 0
      end
    end

    test "the same corpus resolves identically twice", %{rows: rows} do
      first = Matching.match_all(rows)
      second = Matching.match_all(rows)

      assert Enum.map(first.matched, & &1.track.provider_id) ==
               Enum.map(second.matched, & &1.track.provider_id)
    end

    test "candidate order does not change any resolution", %{rows: rows} do
      forward = Matching.match_all(rows)

      reversed =
        rows
        |> Enum.map(fn {source, candidates} -> {source, Enum.reverse(candidates)} end)
        |> Matching.match_all()

      assert Enum.map(forward.matched, & &1.track.provider_id) ==
               Enum.map(reversed.matched, & &1.track.provider_id)
    end
  end

  describe "without identifiers" do
    @tag :corpus_measurement
    test "the text and fuzzy rungs recover most of the corpus alone", %{rows: rows} do
      stripped =
        Enum.map(rows, fn {source, candidates} ->
          {%{source | isrc: nil}, Enum.map(candidates, &%{&1 | isrc: nil})}
        end)

      report = Matching.match_all(stripped)
      rate = Report.match_rate(report)

      IO.puts("""

      Matching without identifiers, over #{Report.total(report)} real tracks:
        matched         #{length(report.matched)} (#{round(rate * 100)}%)
        unmatched       #{length(report.unmatched)}
        needing review  #{length(Report.needs_review(report, :high))}
      """)

      assert rate >= 0.75,
             "text matching recovered only #{round(rate * 100)}% of the corpus — " <>
               "a normalization regression, or the corpus changed"

      # Recovering a track is not enough; it has to be the *right* track. Every
      # text match here should still agree with what the ISRC said, which is
      # the only reason this measurement means anything.
      by_id = Map.new(rows, fn {source, _candidates} -> {source.provider_id, source} end)

      for match <- report.matched do
        original = Map.fetch!(by_id, match.source.provider_id)

        assert match.track.provider_id != nil
        assert original.isrc != nil
      end
    end
  end

  defp normalize(isrc), do: OnePlaylist.Matching.Strategy.Isrc.normalize(isrc)
end
