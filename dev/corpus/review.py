#!/usr/bin/env python3
"""Write the unlabelled credit cases out for a human to judge.

    python3 dev/corpus/review.py > dev/corpus/REVIEW.md      # make the sheet
    python3 dev/corpus/review.py --apply dev/corpus/REVIEW.md  # fold answers back in

A case is unlabelled when no candidate carried the source's ISRC. That is not
the same as "nothing here is right" — a reissue carries a different ISRC — so
the answer has to be looked at rather than inferred.

The sheet proposes an answer for each case. Editing it means changing a line,
not writing one: leave it alone to accept, or change the number in [ ].
"""

import json
import re
import sys

CASES = "dev/corpus/credit_cases.json"


def render():
    cases = json.load(open(CASES))
    unreviewed = [c for c in cases if c["expect"] == "unreviewed"]

    print("# Credit cases needing a judgment\n")
    print(
        "For each: is any listed candidate the *same recording* as the source?\n\n"
        "Edit the `answer:` line only. `0` means none of them is — the engine\n"
        "should decline. Any other number picks that candidate. The proposal is\n"
        "a guess from title and artist similarity; it is often right and is not\n"
        "evidence.\n"
    )

    for index, case in enumerate(unreviewed):
        print(f"## {index + 1}. {case['artist']} — {case['title']}")
        print(f"    album: {case['album']}   length: {case['duration_seconds']}s   "
              f"category: {case['category']}\n")

        if not case["candidates"]:
            print("    (nothing offered)\n")
            print("    answer: 0\n")
            continue

        # Every candidate, not a top few. Showing five of ten made a reviewer
        # answer "none of these" about a list that did not contain the answer,
        # and the replay then scored the engine against that label using all
        # ten. A judgment is only worth as much as the evidence it was given.
        for number, candidate in enumerate(case["candidates"], start=1):
            artists = ", ".join(candidate.get("artists") or []) or "?"
            print(f"    [{number}] {artists} — {candidate['title']}")
            print(f"        {candidate['album']}   {candidate['duration_seconds']}s")

        print(f"\n    answer: {propose(case)}\n")


def propose(case):
    """A cheap guess, so the reviewer is correcting rather than authoring."""
    source_title = (case["title"] or "").lower()
    source_artist = (case["artist"] or "").lower().split()[0] if case["artist"] else ""

    for number, candidate in enumerate(case["candidates"], start=1):
        title = (candidate["title"] or "").lower()
        artists = " ".join(candidate.get("artists") or []).lower()
        # Same title and the lead artist's first word appears: almost always it.
        if title.startswith(source_title[:12]) and source_artist and source_artist in artists:
            return number

    return 0


def apply(path):
    cases = json.load(open(CASES))
    unreviewed = [c for c in cases if c["expect"] == "unreviewed"]

    answers = [int(m) for m in re.findall(r"^\s*answer:\s*(\d+)", open(path).read(), re.M)]

    if len(answers) != len(unreviewed):
        sys.exit(f"expected {len(unreviewed)} answers, found {len(answers)}")

    for case, answer in zip(unreviewed, answers):
        if answer == 0:
            case["expect"] = "decline"
        else:
            case["expect"] = {"match": case["candidates"][answer - 1]["provider_id"]}

    json.dump(cases, open(CASES, "w"), indent=1, ensure_ascii=False)
    print(f"applied {len(answers)} judgments: "
          f"{sum(1 for c in unreviewed if c['expect'] == 'decline')} decline, "
          f"{sum(1 for c in unreviewed if c['expect'] != 'decline')} match")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--apply":
        apply(sys.argv[2])
    else:
        render()
