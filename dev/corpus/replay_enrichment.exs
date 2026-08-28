# Scores enrichment's **text path** against the current engine, offline.
#
#     mix run --no-start dev/corpus/replay_enrichment.exs
#
# The counterpart to `dev/measure/replay.exs`, which does the same for the
# transfer ladder. Until this existed nothing measured enrichment at all: all
# four other corpora replay TIDAL candidates, so every enrichment change was
# evaluated by re-running the live pipeline over a real library and counting.
#
# ## The oracle
#
# A recording identified by **ISRC** was identified by an exact identifier —
# nobody scored anything — so its MBID is ground truth. The question this asks
# is whether the *text* path, given the candidates a search actually returned,
# reaches the same recording.
#
# That is the question enrichment cannot ask about itself: the text path only
# runs when there is no ISRC, which is exactly when there is no label.
#
#   * **correct** — the text path chose the recording the identifier proved.
#   * **equivalent** — it chose a different MBID for what is plainly the same
#     music. MusicBrainz holds duplicate recording entities in quantity, and one
#     album's pressings each carry their own: *Purple Haze* on *Are You
#     Experienced* exists at 171s and at 173s under two ids. Counting those as
#     failures was the first version of this file and it reported 28 of 120
#     wrong, of which the first six sampled were five duplicates and one real
#     error.
#   * **missed** — it declined. Costs an identification; costs nothing wrong.
#   * **WRONG** — it chose different music. The failure that matters, because
#     enrichment writes what it decides onto a shared, ownerless row.
#
# Equivalence is decided in the order the evidence deserves: the chosen
# candidate carrying the **source's own ISRC** settles it outright — that is the
# same recording by identifier, whatever the ids say. Failing that, an agreeing
# normalized title and a length within three seconds.
#
# **Album agreement was a requirement and is not one**, which was measurably
# wrong: it counted a recording on a compilation or an anniversary reissue as an
# error. Of thirteen the first version called wrong, eleven were the same
# recording — *Kick* against *Kick 30*, *Wish You Were Here* against *Wish You
# Were Here 50*, *Free Bird* at 550s against a Collector's Edition at 548s.
# A recording appears on as many albums as it appears on; the album says almost
# nothing about whether two ids name one performance, and the length says a
# great deal.
#
# The title check is what still does the discriminating, and it is enough: of
# the two genuine errors, both are caught by it — *Call Me Maybe (Dark
# Intensity)* and *Angel (Angel Dust)* do not normalize to *Call Me Maybe* and
# *Angel*.
#
# **Where a length is missing on either side there is no third piece of
# evidence, so the case is reported as `unverified` rather than guessed at.**
# Counting those as equivalent would flatter the engine and counting them as
# wrong would libel it; they are three of the thirteen, and saying so is more
# useful than picking.
#
# The unlabelled half — recordings still unidentified — cannot say whether a
# change is right, only whether it unlocks anything. Reported separately, and
# never mixed into the accuracy figure.
#
# ## Why several thresholds
#
# `chosen/2` accepts at the **text band's ceiling**, which is reachable only
# when every signal is exactly `1.0`. Duration is one of them, and pressings of
# one album differ by seconds — so a candidate that states its length is held to
# a stricter standard than one that says nothing. *Ripple* on *American Beauty*
# scores `0.9717` against a real pressing three seconds out and is refused.
#
# Lowering it is not obviously safe, which is why this reports a range rather
# than an opinion: the WRONG column is what decides.
#
# ## The release-first rung
#
# `by_release_tracks/2` asks the question the other way round: find the
# **release** by album name, then look for our title among its tracks. It runs
# only when everything above has declined, so it shows up in the report as a
# separate row and as a `via_release` column — how many of that row's answers it
# supplied.
#
# Its hits are scored the same way, with one honest limit: a release document
# names a recording id and a *track* title, not the recording's own title or its
# ISRC, so an id that differs from the expected one cannot be classified as
# `equivalent` the way a search candidate can. Those are counted as **WRONG**,
# which overstates them. The number to read is therefore an upper bound on its
# cost and an exact count of its gain.
#
# ## The control row
#
# `release_tags` — `:live`, `:remix`, `:demo`, read off a candidate's release
# **group** secondary types — feed the discriminating veto, which is the only
# thing standing between a studio recording and a remix of it whose parenthetical
# `Normalize.title/1` has just stripped.
#
# `tags withheld` runs the identical ladder over the identical candidates with
# every tag removed, so the difference between it and `+ release-first` is what
# the tags did — isolated from the capture, which is the only way to read a
# re-harvested corpus at all.
#
# Read **both** directions of that difference, because a veto has both:
#
#   * **the cost** is in `missed` — a tag that disagrees refuses a match, and
#     every label here is a should-match case, so a veto can only lose them;
#   * **the gain** is in `WRONG`, and it is visible here rather than only in the
#     unit tests, because the rule was *derived from this corpus*. Its two
#     genuine errors were *Call Me Maybe (Dark Intensity)* and *Angel (Angel
#     Dust)*, and both are remixes whose parenthetical `Normalize.title/1`
#     strips — leaving the release group's `Remix` type as the only surviving
#     trace. Withholding tags should hand them back.
#
# The one thing this cannot pose is a false positive against music the corpus
# does not contain; `test/one_playlist/matching/signals_test.exs` carries those.
#
# ## Two rejected rules, kept as rows
#
# Both were proposed here with confidence and both are refused by this corpus,
# which is why they stay in the output rather than in somebody's memory.
#
#   * **A lower threshold.** Every step down trades a miss for a wrong at
#     roughly one for one — 0.98 gives 34 missed and 8 wrong, 0.95 gives 26 and
#     16. `dev/corpus/replay_album_cases.exs` states the policy this project
#     holds to: a false negative costs a cover or a barcode, and is never worth
#     trading a false positive for. Enrichment writes onto a shared row, so the
#     asymmetry is sharper here than anywhere else.
#
#   * **Textual exactness with duration demoted to a non-conflict.** The idea
#     that duration should corroborate rather than gate, which is what *Ripple*
#     seems to argue for. It gains two right answers and more than doubles the
#     wrong ones, 8 to 20 — because among many recordings of one song, an exact
#     title and credit do not separate them and the length was doing the work.

alias OnePlaylist.Matching
alias OnePlaylist.Matching.Confidence
alias OnePlaylist.Matching.Signals
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.Music.Track

cases = "dev/corpus/enrichment_cases.json" |> File.read!() |> Jason.decode!()

to_track = fn map, provider, tags? ->
  %Track{
    provider: provider,
    provider_id: map["provider_id"] || "source",
    title: map["title"],
    artists: map["artists"] || [],
    album: map["album"],
    album_titles: map["album_titles"] || [],
    title_variants: map["title_variants"] || [],
    # `live_release?` is the field this replaced; a corpus harvested before the
    # generalisation still carries it, and reading both keeps an older capture
    # scoreable rather than silently scoring it wrong.
    release_tags:
      if tags? do
        Enum.map(map["release_tags"] || [], &String.to_existing_atom/1) ++
          if(map["live_release?"], do: [:live], else: [])
      else
        []
      end,
    duration_seconds: map["duration_seconds"],
    isrc: map["isrc"],
    album_upc: map["album_upc"],
    version: map["version"]
  }
end

# `by_name/1`'s own order: the release-qualified search first, because naming the
# release is worth more than any other term the query can carry, then the broad
# one. A decline on the narrow question falls through rather than ending it.
decide = fn case_, threshold, tags? ->
  source = to_track.(case_, :library, tags?)

  attempt = fn candidates ->
    tracks = Enum.map(candidates || [], &to_track.(&1, :musicbrainz, tags?))

    case tracks do
      [] -> :none
      _ -> Matching.match(source, tracks, threshold: threshold)
    end
  end

  case attempt.(case_["qualified_candidates"]) do
    {:ok, match} ->
      {:chose, match.track}

    _declined ->
      case attempt.(case_["broad_candidates"]) do
        {:ok, match} -> {:chose, match.track}
        _also_declined -> :declined
      end
  end
end

# The last rung, replayed from the release documents the harvest captured. This
# mirrors `Enrichment.by_release_tracks/2` exactly, including the rule that makes
# it safe: every matching track across the fetched releases must name the **same**
# recording. Three pressings of one show agree by construction; two different
# nights that both contain a song do not.
release_first = fn case_ ->
  ours = Normalize.title(case_["title"] || "").title
  our_seconds = case_["duration_seconds"]

  hits =
    (case_["releases"] || %{})
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn document ->
      (document["tracks"] || [])
      |> Enum.filter(fn track ->
        length_ok? =
          is_nil(our_seconds) or is_nil(track["length_ms"]) or
            abs(our_seconds - div(track["length_ms"], 1000)) <= 3

        Normalize.title(track["title"] || "").title == ours and length_ok?
      end)
      |> Enum.map(&{&1["recording_mbid"], &1["title"], document["title"], &1["length_ms"]})
    end)
    |> Enum.reject(fn {id, _t, _r, _l} -> is_nil(id) end)

  case Enum.uniq(Enum.map(hits, &elem(&1, 0))) do
    [only] ->
      # The pseudo-track a release document can support: the **track** title,
      # which is what matched, and the release title as its album. Not as strong
      # as a search candidate — there is no ISRC and no recording title — but
      # enough for the equivalence test, and without it every duplicate
      # MusicBrainz entity counts against this rung.
      {_id, track_title, release_title, length_ms} = Enum.find(hits, &(elem(&1, 0) == only))

      {:chose_mbid, only,
       %Track{
         provider: :musicbrainz,
         provider_id: only,
         title: track_title,
         artists: case_["artists"] || [],
         album: release_title,
         duration_seconds: length_ms && div(length_ms, 1000)
       }}

    _none_or_disagreed ->
      :declined
  end
end

# The whole ladder as it stands: the text rungs, then the release rung.
decide_with_release = fn case_, threshold, tags? ->
  case decide.(case_, threshold, tags?) do
    :declined -> release_first.(case_)
    chose -> chose
  end
end

# The same music under another id, as opposed to other music.
verdict_for = fn case_, chosen ->
  same_isrc? = is_binary(case_["isrc"]) and chosen.isrc == case_["isrc"]
  same_title? = Normalize.title(case_["title"]).title == Normalize.title(chosen.title).title

  ours = case_["duration_seconds"]
  theirs = chosen.duration_seconds

  cond do
    same_isrc? -> :equivalent
    not same_title? -> :wrong
    is_nil(ours) or is_nil(theirs) -> :unverified
    abs(ours - theirs) <= 3 -> :equivalent
    true -> :wrong
  end
end

{labelled, unlabelled} = Enum.split_with(cases, & &1["expected_mbid"])

score = fn threshold, decider ->
  verdicts =
    Enum.map(labelled, fn case_ ->
      case decider.(case_, threshold) do
        {:chose, chosen} ->
          cond do
            chosen.provider_id == case_["expected_mbid"] -> :correct
            true -> verdict_for.(case_, chosen)
          end

        # A release document supports a weaker equivalence test than a search
        # candidate does — no ISRC, and the recording's own title is not in it —
        # but the track title and the release title are, and those are what
        # separate a duplicate entity from different music. Measured: of seven
        # disagreements, six were the same track on the same album.
        {:chose_mbid, mbid, pseudo} ->
          cond do
            mbid == case_["expected_mbid"] -> :correct
            true -> verdict_for.(case_, pseudo)
          end

        :declined ->
          :missed
      end
    end)

  unlocked =
    Enum.count(unlabelled, fn case_ ->
      match?({:chose, _}, decider.(case_, threshold)) or
        match?({:chose_mbid, _, _}, decider.(case_, threshold))
    end)

  via_release =
    Enum.count(labelled ++ unlabelled, fn case_ ->
      match?({:chose_mbid, _, _}, decider.(case_, threshold))
    end)

  %{
    threshold: threshold,
    correct: Enum.count(verdicts, &(&1 == :correct)),
    equivalent: Enum.count(verdicts, &(&1 == :equivalent)),
    unverified: Enum.count(verdicts, &(&1 == :unverified)),
    missed: Enum.count(verdicts, &(&1 == :missed)),
    WRONG: Enum.count(verdicts, &(&1 == :wrong)),
    unlabelled_now_matching: unlocked,
    via_release: via_release
  }
end

# The alternative to lowering the threshold, and a different claim.
#
# The ceiling is unreachable unless *every* signal is exactly 1.0, and duration
# is one of them — so a candidate stating its length is held to a stricter
# standard than one saying nothing, and *Ripple* on *American Beauty* is refused
# over three seconds between pressings.
#
# This asks for exactness where exactness is meaningful — title, album, credit —
# and asks duration only not to *conflict*, which is already its own signal and
# already vetoes a genuinely different performance. Lowering the threshold
# admits candidates with imperfect titles too; this does not.
textually_exact = fn source, candidates ->
  candidates
  |> Enum.map(&{&1, Signals.compare(source, &1)})
  |> Enum.filter(fn {_c, s} ->
    not Signals.vetoed?(s) and not s.duration_conflict and
      s.title == 1.0 and s.credit_match == :same and (is_nil(s.album) or s.album == 1.0)
  end)
  |> Enum.max_by(fn {_c, s} -> s.duration || 0.0 end, fn -> nil end)
  |> case do
    nil -> :declined
    {candidate, _s} -> {:chose, candidate}
  end
end

decide_textual = fn case_, _threshold ->
  source = to_track.(case_, :library, true)

  narrow = Enum.map(case_["qualified_candidates"] || [], &to_track.(&1, :musicbrainz, true))
  broad = Enum.map(case_["broad_candidates"] || [], &to_track.(&1, :musicbrainz, true))

  case textually_exact.(source, narrow) do
    {:chose, _} = found -> found
    :declined -> textually_exact.(source, broad)
  end
end

ceiling = elem(Confidence.band(:text), 1)

IO.puts("""

enrichment text path — #{length(labelled)} labelled, #{length(unlabelled)} unlabelled
the current rule is threshold #{ceiling}, the text band's ceiling
""")

# The threshold sweep asks the text rungs only, so a threshold's cost is not
# hidden by a later rung recovering from it.
text_only = fn case_, threshold -> decide.(case_, threshold, true) end

# The whole ladder, which is what the engine actually does.
full = fn case_, threshold -> decide_with_release.(case_, threshold, true) end

# The same ladder with every release tag withheld — the control. See the header.
untagged = fn case_, threshold -> decide_with_release.(case_, threshold, false) end

rows =
  Enum.map([ceiling, 0.97, 0.96, 0.95, 0.93, 0.90], &{"threshold #{:erlang.float_to_binary(&1, decimals: 2)}", score.(&1, text_only)}) ++
    [
      {"textually exact", score.(ceiling, decide_textual)},
      {"+ release-first", score.(ceiling, full)},
      {"tags withheld", score.(ceiling, untagged)}
    ]

Enum.each(rows, fn {name, row} ->
  mark = if name == "threshold 0.98", do: "  <- current", else: ""

  IO.puts(
    "  #{String.pad_trailing(name, 16)}" <>
      "   correct #{String.pad_leading(to_string(row.correct), 3)}" <>
      "   equiv #{String.pad_leading(to_string(row.equivalent), 3)}" <>
      "   unver #{String.pad_leading(to_string(row.unverified), 3)}" <>
      "   missed #{String.pad_leading(to_string(row.missed), 3)}" <>
      "   WRONG #{String.pad_leading(to_string(row[:WRONG]), 3)}" <>
      "   unlocked #{String.pad_leading(to_string(row.unlabelled_now_matching), 3)}" <>
      "   via-release #{String.pad_leading(to_string(row.via_release), 3)}" <> mark
  )
end)

IO.puts("")
