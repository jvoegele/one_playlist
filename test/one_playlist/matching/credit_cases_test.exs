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
  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.Music.Track

  @corpus "dev/corpus/credit_cases.json"

  # Three of these left when partial credit overlap stopped being read as
  # `:unrelated` — the two Ghostface cases and 2Pac's "Thug Passion", where the
  # catalogue spells Cappadonna "Capadonna" and Dramacydal had become Outlawz.
  # Both are artist renamings, which is what an alias table would have bought,
  # obtained here from the overlap alone.
  #
  # Declined a candidate that was offered and correct. Less bad than a wrong
  # match — the report says so, and the row can be corrected by hand — but this
  # is the backlog, and two of these are worth naming precisely.
  #
  # Johnny Cash's "Jackson" and The Doors' "Break on Through" are live
  # recordings whose source album names the venue while the *title* says
  # nothing. TIDAL labels its copy "Live at Folsom State Prison", the veto sees
  # a marker on one side only, and refuses. The source is equally live.
  #
  # An exception for "the releases agree" was written, measured — it recovered
  # both, gained three cases overall, and cost nothing on the MusicBrainz
  # corpus — and then **reverted**, because it broke the karaoke, cover,
  # instrumental and live-vs-studio tests. The premise it rested on, that a
  # release does not carry two recordings under one title, is simply false: a
  # deluxe edition carries "Yesterday" and "Yesterday - Live at the BBC". Those
  # four cases are the product's central promise and outrank three corpus rows.
  #
  # Fixing these needs to know that *At Folsom Prison* is a live album, which no
  # amount of string comparison can tell. See `docs/reference/domain.md`.
  @missed [
    "De La Soul with Jungle Brothers and Q-Tip - Buddy",
    "James Brown - Brother Rapp / Ain't It Funky Now (live)",
    "James Brown - It's a New Day (live)",
    "Johnny Cash with June Carter Cash - Jackson",
    "Kanye West - Pinocchio Story (freestyle live from Singapore)",
    "SpongeBob, Patrick & The Monsters - Now That We're Men",
    "The Doors with Eddie Vedder - Break on Through"
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

  # `:equivalent` is the allowance `dev/measure/replay.exs` makes as
  # `duration_corroborated`, and it is not generosity. An ISRC names a recording
  # *as issued*, so a catalogue holding the same recording on two releases has
  # two of them and the oracle can only name one. Prince's "Purple Rain" forced
  # it: the engine chose a candidate one second from the source where the
  # labelled answer is seven seconds off. Scoring that as wrong would measure
  # the label's arbitrariness, not the engine.
  #
  # The bar is tight on purpose — same normalized title, within three seconds —
  # because a loose one absorbs the errors this corpus exists to find.
  defp classify(kase) do
    wanted = kase["expect"]["match"]
    source = source(kase)

    case Matching.match(source, Enum.map(kase["candidates"], &candidate/1)) do
      {:ok, %{track: %{provider_id: ^wanted}}} -> :correct
      {:ok, %{track: chosen}} -> if equivalent?(source, chosen), do: :equivalent, else: :wrong
      {:error, _reason} -> :missed
    end
  end

  defp equivalent?(source, chosen) do
    same_title =
      Normalize.title(source.title, source.version).title ==
        Normalize.title(chosen.title, chosen.version).title

    close? =
      is_integer(source.duration_seconds) and is_integer(chosen.duration_seconds) and
        abs(source.duration_seconds - chosen.duration_seconds) <= 3

    same_title and close?
  end

  defp label(kase), do: "#{kase["artist"]} - #{kase["title"]}"

  describe "the credit corpus" do
    test "every judged case behaves exactly as recorded" do
      judged = Enum.filter(cases(), &is_map(&1["expect"]))

      assert length(judged) > 60,
             "the corpus lost its labelled cases; re-run dev/corpus/fetch_credit_cases.exs"

      graded = Enum.group_by(judged, &classify/1, &label/1)

      assert graded[:wrong] == nil,
             """
             A credit case now resolves to the wrong recording.

             This is the failure the corpus was built to catch, and there were
             none: #{inspect(graded[:wrong])}
             """

      assert Enum.sort(graded[:missed] || []) == Enum.sort(@missed),
             """
             The set of missed credit cases changed.

             A name that appeared is a regression. A name that disappeared is an
             improvement, and this list should be updated to claim it.
             """
    end

    test "nothing matches a recording a person said was not there" do
      # The cases an ISRC oracle cannot produce, and the only ones that can
      # catch a match that should never have happened. Every one of these was
      # looked at by hand against the *whole* candidate list — an earlier
      # review sheet showed five of ten and produced a "none of these" about a
      # list that did not contain the answer.
      declines = Enum.filter(cases(), &(&1["expect"] == "decline"))

      assert length(declines) >= 5, "the decline labels are what make this test possible"

      for kase <- declines do
        assert {:error, _reason} =
                 Matching.match(source(kase), Enum.map(kase["candidates"], &candidate/1)),
               "matched something for #{label(kase)}, which has no counterpart on the destination"
      end
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
