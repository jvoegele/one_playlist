#!/usr/bin/env python3
"""Harvest labelled album-title pairs from MusicBrainz.

    python3 dev/corpus/harvest_albums.py > dev/corpus/album_cases.json

Every album-normalization decision this project has made so far rests on twelve
hand-labelled cases from one playlist, and every trap in it was found by
accident: "Greatest Hits" against "Greatest Hits Vol. 2", "Ten" against "Ten
Redux", "Pearl Jam" against the store-invented "Pearl Jam - Non-Album Tracks".
A rule tuned against the cases you happened to trip over is tuned against your
own luck.

## The labels are free, because MusicBrainz already draws the line

A **release group** *is* an album across all its pressings — the original, the
reissue, the Japanese edition, the remaster. So the ground truth needs no
hand-labelling at all:

  * two release titles in the **same group** name the same album — a positive;
  * two release titles in **different groups by one artist** name different
    albums — a negative.

That second half is why this is worth harvesting rather than inventing. The hard
negatives fall out for free, because same-artist different-group pairs are
exactly where titles look alike, and they are the pairs a normalization rule
gets wrong.

## Only confusable pairs are kept, in **both** directions

A corpus of "Nevermind" against "In Utero" measures nothing — any rule gets it
right. So a pair is kept only when the two titles are similar enough to be
confusable, and the same floor applies to positives and negatives alike. That
symmetry is the point: the corpus then asks exactly the question the rule
answers — *of these lookalikes, which name one album?* — rather than rewarding a
rule for the easy half of either side.

The first version applied the floor to negatives only, and the result measured
something else entirely. A positive pair of "1991-10-06: Hollywood, CA, USA" and
"Wash My Love" is two pressings of one bootleg with unrelated names: true, and
unreachable by any string rule, so counting it as a failure says nothing about
the rule under test.

## Albums only, because that is what the field holds

A track's `album` names an album. Singles are excluded because a single's title
is routinely distinguished *by* the very bracket a normalization rule strips —
"Street Spirit (Fade Out)" and "Street Spirit (Oakenfold remix)" are two
different records — so including them measures the rule against strings it is
never asked about.

## The labels are not perfect, and the corpus says by how much

MusicBrainz holds duplicate release groups for the same album, so a pair labelled
*different* is sometimes the same record twice: "The Times They Are A‐Changin'"
against "The Times They Are A-Changin'" differs only in which dash character was
typed. Plain `Normalize.text/1` equality — which cannot loosen anything — still
reports ten such pairs, and that is the corpus's noise floor rather than a defect
in any rule. `replay_album_cases.exs` prints the baseline for exactly this
reason: a rule is worth judging against it, not against zero.

## Live bootlegs are excluded, and they are most of the raw data

A heavily bootlegged artist has hundreds of date-titled releases, and they
crowded out everything else — every kept pair was two gig dates, similar only
because they share a date format. Release groups whose secondary types include
*Live*, and releases marked *Bootleg*, are dropped. **Compilations stay**: they
are where "Greatest Hits Vol. 2" lives, which is the trap this exists for.

## Sampled across groups rather than taken in order

Taking the first N pairs takes them all from one or two prolific groups. Pairs
are drawn round-robin so an artist's allowance spreads over their catalogue.

## One request per page, one second apart

MusicBrainz asks for a request a second and means it. Browsing releases with
`inc=release-groups` returns each release *with* the group it belongs to, so an
artist costs a search plus a page or two rather than a call per group.
"""

import json
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from difflib import SequenceMatcher

BASE = "https://musicbrainz.org/ws/2"
AGENT = "OnePlaylist/0.1 ( https://github.com/jvoegele/one_playlist )"

# Chosen for the shapes that break a normalization rule rather than for taste:
# long reissue histories, live records named after venues and dates, greatest
# hits with volume numbers, and box sets that pair two albums on one release.
ARTISTS = [
    "Pearl Jam", "Bruce Springsteen", "Bob Dylan", "Neil Young", "The Beatles",
    "Miles Davis", "John Coltrane", "Led Zeppelin", "Pink Floyd", "The Who",
    "Radiohead", "Nirvana", "R.E.M.", "Tom Waits", "Joni Mitchell",
    "The Rolling Stones", "David Bowie", "Prince", "Kate Bush", "Talking Heads",
    "Fleetwood Mac", "Grateful Dead", "Johnny Cash", "Aretha Franklin",
    "Stevie Wonder", "Marvin Gaye", "Nina Simone", "Bill Evans",
    "Sonic Youth", "The Cure", "Depeche Mode", "New Order", "Massive Attack",
    "Portishead", "Björk", "Sigur Rós", "Wilco", "Uncle Tupelo",
    "The Clash", "Elvis Costello",
]

# A negative below this is not confusable and teaches nothing.
CONFUSABLE = 0.6

# Bounded so one prolific artist cannot dominate the file.
PER_ARTIST_POSITIVES = 12
PER_ARTIST_NEGATIVES = 12

# Release groups of these kinds are dropped: a bootlegged artist has hundreds of
# date-titled live releases and they crowd out every other shape.
EXCLUDED_TYPES = {"Live", "Bootleg", "Interview", "Demo"}

# Only what a track's `album` field actually names. A single's title is often
# distinguished *by* its bracket — "Street Spirit (Fade Out)" against "Street
# Spirit (Oakenfold remix)" are two different records — so including singles
# measures a rule against strings it is never asked about, and punishes it for
# the one shape where stripping a bracket is genuinely wrong.
#
# `Album` keeps compilations, which carry their secondary type: they are where
# "Greatest Hits Vol. 2" lives and are the trap this exists for.
INCLUDED_PRIMARY = {"Album"}

PAGES = 3
PAGE_SIZE = 100


def get(path, params):
    params = dict(params, fmt="json")
    url = f"{BASE}{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})

    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except Exception as error:  # noqa: BLE001 — a harvester retries anything
            if attempt == 3:
                print(f"  giving up on {path}: {error}", file=sys.stderr)
                return {}
            time.sleep(2 ** attempt)
        finally:
            time.sleep(1.1)

    return {}


def artist_id(name):
    found = get("/artist", {"query": f'artist:"{name}"', "limit": 1}).get("artists", [])

    return found[0]["id"] if found else None


def releases_by_group(mbid):
    """Every release this artist has, indexed by the album it is a pressing of."""
    groups = defaultdict(set)

    for page in range(PAGES):
        body = get(
            "/release",
            {
                "artist": mbid,
                "inc": "release-groups",
                "limit": PAGE_SIZE,
                "offset": page * PAGE_SIZE,
            },
        )

        releases = body.get("releases", [])

        for release in releases:
            group = release.get("release-group") or {}
            title = release.get("title")
            secondary = set(group.get("secondary-types") or [])

            if not group.get("id") or not title:
                continue

            if secondary & EXCLUDED_TYPES or release.get("status") == "Bootleg":
                continue

            if group.get("primary-type") not in INCLUDED_PRIMARY:
                continue

            groups[(group["id"], group.get("title"))].add(title)

        if len(releases) < PAGE_SIZE:
            break

    return groups


def similar(left, right):
    return SequenceMatcher(None, left.lower(), right.lower()).ratio()


def round_robin(by_group, limit):
    """One pair from each group in turn, so no single album fills the quota."""
    taken, exhausted = [], False

    while len(taken) < limit and not exhausted:
        exhausted = True

        for pairs in by_group.values():
            if pairs:
                taken.append(pairs.pop(0))
                exhausted = False

                if len(taken) == limit:
                    break

    return taken


def pairs_for(artist, groups):
    by_group_positive = {}

    for key, titles in groups.items():
        _group_id, group_title = key
        distinct = sorted(titles)
        found = []

        for i, left in enumerate(distinct):
            for right in distinct[i + 1:]:
                if left != right and similar(left, right) >= CONFUSABLE:
                    found.append((left, right, "two pressings of one album"))

            if group_title and group_title != left and similar(group_title, left) >= CONFUSABLE:
                found.append((group_title, left, "a pressing against its album"))

        if found:
            by_group_positive[key] = found

    named = [
        (title, group_title)
        for (_id, group_title), titles in groups.items()
        for title in titles
    ]

    by_group_negative = defaultdict(list)

    for i, (left, left_group) in enumerate(named):
        for right, right_group in named[i + 1:]:
            if left_group == right_group or left == right:
                continue

            if similar(left, right) >= CONFUSABLE:
                by_group_negative[left_group].append(
                    (left, right, "different albums, confusable titles")
                )

    return (
        [dict(left=l, right=r, same_album=True, artist=artist, why=w)
         for l, r, w in round_robin(by_group_positive, PER_ARTIST_POSITIVES)],
        [dict(left=l, right=r, same_album=False, artist=artist, why=w)
         for l, r, w in round_robin(by_group_negative, PER_ARTIST_NEGATIVES)],
    )


def main():
    cases = []

    for artist in ARTISTS:
        print(f"{artist}…", file=sys.stderr, end=" ", flush=True)

        mbid = artist_id(artist)

        if not mbid:
            print("not found", file=sys.stderr)
            continue

        positives, negatives = pairs_for(artist, releases_by_group(mbid))
        cases.extend(positives + negatives)

        print(f"{len(positives)} same, {len(negatives)} different", file=sys.stderr)

    same = sum(1 for case in cases if case["same_album"])

    print(
        f"\n{len(cases)} pairs: {same} same album, {len(cases) - same} different",
        file=sys.stderr,
    )

    json.dump(cases, sys.stdout, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
