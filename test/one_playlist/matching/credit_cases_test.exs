defmodule OnePlaylist.Matching.CreditCasesTest do
  @moduledoc """
  The matching engine against the credit corpus.

  ## Why this exists separately from the MusicBrainz measurement

  `dev/measure/replay.exs` scores a hundred randomly chosen recordings, and
  almost none of them has a multi-part credit. An engine change that was plainly
  wrong about collaborations measured as *neutral* there — it moved two tracks,
  both of them for unrelated reasons — while putting a Neil Young solo recording
  into a Pearl Jam playlist. A corpus that cannot see a class of error cannot
  defend against it.

  These 120 cases were harvested from a real library by
  `dev/corpus/harvest_credits.py`, filtered to exactly the credits the engine
  finds hard: guest credits, ampersands, "with", "and", listed collaborators,
  and version markers in the title. They are six times more error-prone than a
  random sample — 6.3% wrong against 1% — which is the point.

  ## The oracle

  Every judged case carries an ISRC that a TIDAL candidate also carries, and the
  ISRC is **withheld from the source** at replay. So the right answer is known
  without anybody's opinion, and the identifier rung cannot supply it.

  Cases where no offered candidate carried the ISRC are marked `"unreviewed"`
  and are not asserted on. That is not the same as "should decline": TIDAL may
  hold the recording under a reissue's ISRC, which is a real thing that
  `Tidal.by_isrc/4` had to be fixed for. Labelling those needs a person.

  ## Why the known failures are listed by name

  Asserting a *count* would let one case start failing while another started
  passing. Naming them means a regression fails the build and an improvement
  fails it too — which is the intent. A fix that moves a name out of this list
  should have to say so.
  """

  use ExUnit.Case, async: true

  alias OnePlaylist.Matching
  alias OnePlaylist.Music.Track

  @corpus "dev/corpus/credit_cases.json"

  # Chosen the wrong candidate. Every one of these is a real defect and a
  # candidate for the next round of work.
  @wrong [
    "2Pac feat. Danny Boy - I Ain't Mad at Cha",
    "Beastie Boys feat. Santigold - Don't Play No Game That I Can't Win",
    "JAY Z + Young Jeezy - Real as It Gets",
    "JAY Z feat. Beanie Sigel, Memphis Bleek & Amil - Pop 4 Roc",
    "Johnny Cash with June Carter Cash - Give My Love to Rose"
  ]

  # Declined a candidate that was offered and correct. Less bad than a wrong
  # match — the report says so and the track can be corrected by hand — but
  # still a miss.
  @missed [
    "Ghostface Killah feat. Raekwon & Theodore Unit (Trife Diesel, Cappadonna & Sun God) - Dogs of War",
    "Ghostface Killah feat. Theodore Unit (Cappadonna, Shawn Wigs & Trife Diesel) - Jellyfish",
    "James Brown - Brother Rapp / Ain't It Funky Now (live)",
    "James Brown - It's a New Day (live)",
    "Kanye West - Pinocchio Story (freestyle live from Singapore)",
    "SpongeBob, Patrick & The Monsters - Now That We're Men"
  ]

  defp cases do
    @corpus |> File.read!() |> Jason.decode!()
  end

  defp source(kase) do
    # No ISRC. It is the oracle, not an input.
    %Track{
      provider: :file,
      provider_id: "s",
      isrc: nil,
      title: kase["title"],
      album: kase["album"],
      artists: [kase["artist"]],
      duration_seconds: kase["duration_seconds"]
    }
  end

  defp candidate(c) do
    %Track{
      provider: :tidal,
      provider_id: c["provider_id"],
      isrc: c["isrc"],
      title: c["title"],
      version: c["version"],
      album: c["album"],
      album_upc: c["album_upc"],
      artists: c["artists"] || [],
      duration_seconds: c["duration_seconds"]
    }
  end

  defp classify(kase) do
    wanted = kase["expect"]["match"]

    case Matching.match(source(kase), Enum.map(kase["candidates"], &candidate/1)) do
      {:ok, %{track: %{provider_id: ^wanted}}} -> :correct
      {:ok, _other} -> :wrong
      {:error, _reason} -> :missed
    end
  end

  defp label(kase), do: "#{kase["artist"]} - #{kase["title"]}"

  describe "the credit corpus" do
    test "every judged case behaves exactly as recorded" do
      judged = Enum.filter(cases(), &is_map(&1["expect"]))

      assert length(judged) > 60,
             "the corpus lost its labelled cases; re-run dev/corpus/fetch_credit_cases.exs"

      graded = Enum.group_by(judged, &classify/1, &label/1)

      assert Enum.sort(graded[:wrong] || []) == Enum.sort(@wrong),
             """
             The set of wrongly-matched credit cases changed.

             A name that appeared is a regression. A name that disappeared is an
             improvement, and this list should be updated to claim it.
             """

      assert Enum.sort(graded[:missed] || []) == Enum.sort(@missed),
             "The set of missed credit cases changed."
    end

    test "the corpus still covers every category it was built to cover" do
      # A harvest that quietly stopped finding "with" credits would leave the
      # test above passing over a corpus that no longer measures anything.
      covered = cases() |> Enum.map(& &1["category"]) |> Enum.frequencies()

      for category <- ~w(guest ampersand with and listed version) do
        assert Map.get(covered, category, 0) >= 10,
               "category #{category} has thinned out to #{Map.get(covered, category, 0)}"
      end
    end
  end
end
