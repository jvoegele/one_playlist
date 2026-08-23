#!/usr/bin/env python3
"""Assemble a playlist designed to break the matching engine.

    python3 dev/experiments/build_hard_playlist.py ~/Music/Library \
      > dev/experiments/hard_playlist.csv

Every category below is a failure mode this project has actually hit, or one
that nothing has tested yet. A playlist of mainstream albums with full ISRC
coverage matches 58 of 58 and teaches nothing; this is the opposite.

Written in Roon's export format — `title;artist;album;isrc`, semicolon
delimited — because that is what the CSV reader is built for, and because a
semicolon *inside* a field then has to be quoted, which is itself worth
exercising: 567 tracks in this library carry two ISRCs in one tag.

A companion `hard_playlist_categories.json` records which category each row came
from, so a report can be read by failure mode rather than as one number.
"""

import csv
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

EXTENSIONS = (".flac", ".mp3", ".m4a", ".ogg", ".wav", ".aiff")

PER_CATEGORY = 8

non_ascii = lambda s: any(ord(c) > 127 for c in (s or ""))

# Each entry: a predicate, and what it is meant to prove.
CATEGORIES = [
    (
        "version_in_title",
        # The version veto's home ground: "(Live)", "(Remix)", "(Acoustic)".
        lambda r: re.search(r"\((?:[^)]*\b(live|remix|acoustic|demo|instrumental|reprise)\b[^)]*)\)", r["title"] or "", re.I),
    ),
    (
        "live_album_plain_title",
        # The veto's blind spot, and the Johnny Cash "Jackson" case: the source
        # is live and only its *album* says so, so a correctly-labelled live
        # candidate is refused by a source that is equally live.
        lambda r: re.search(r"\blive\b", r["album"] or "", re.I)
        and not re.search(r"\blive\b", r["title"] or "", re.I),
    ),
    (
        "no_isrc",
        # Forces the text ladder, where every credit rule actually applies.
        lambda r: not r["isrc"],
    ),
    (
        "multi_isrc",
        # Two ISRCs in one tag. `Music.Isrc.normalize/1` rejects a 25-character
        # value outright, so this should lose the identifier entirely — and the
        # semicolon has to survive CSV quoting to get here at all.
        lambda r: ";" in (r["isrc"] or ""),
    ),
    (
        "non_ascii_artist",
        # Diacritics normalise; non-Latin scripts do not, and nothing has tested
        # what happens then.
        lambda r: non_ascii(r["artist"]),
    ),
    (
        "non_ascii_title",
        lambda r: non_ascii(r["title"]) and not non_ascii(r["artist"]),
    ),
    (
        "classical",
        # Never tested. A classical credit names a performer where the catalogue
        # may name a composer, and titles carry opus numbers and movements.
        lambda r: re.search(r"\b(op\.|bwv|k\.|symphony|concerto|sonata|quartet|movement|allegro|adagio)\b",
                            (r["title"] or "") + " " + (r["album"] or ""), re.I),
    ),
    (
        "long_credit",
        # Thirty characters of collaborators is a text query that returns
        # nothing usable — the Ghostface and 2Pac corpus failures.
        lambda r: len(r["artist"] or "") > 40,
    ),
    (
        "medley",
        # A slash title names two songs. No catalogue carries it as one track
        # unless the release does, so the right answer is often "decline".
        lambda r: "/" in (r["title"] or ""),
    ),
    (
        "guest_credit",
        lambda r: re.search(r"\s(feat\.?|ft\.?|featuring)\s", r["artist"] or "", re.I),
    ),
    (
        "co_billed",
        # "&", "and", "with" — collaboration against backing band, the
        # distinction no rule over the strings can make.
        lambda r: re.search(r"\s&\s|\sand\s|\swith\s|\s\+\s", r["artist"] or "", re.I),
    ),
]


def probe(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=20).stdout
        tags = {k.lower(): v for k, v in ((json.loads(out).get("format") or {}).get("tags") or {}).items()}
        return {
            "artist": tags.get("artist"),
            "title": tags.get("title"),
            "album": tags.get("album"),
            "isrc": (tags.get("isrc") or "").strip() or None,
        }
    except Exception:
        return None


def main(root):
    paths = [os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns
             if n.lower().endswith(EXTENSIONS)]

    with ThreadPoolExecutor(max_workers=16) as pool:
        rows = [r for r in pool.map(probe, paths) if r and r.get("artist") and r.get("title")]

    # One row per (artist, title): the same track on three compilations is one
    # test, not three.
    seen, unique = set(), []
    for r in rows:
        key = ((r["artist"] or "").lower(), (r["title"] or "").lower())
        if key not in seen:
            seen.add(key)
            unique.append(r)

    # Titles carried by more than one artist. Picking the *less* prolific
    # artist's version makes a wrong match to the famous one possible, which is
    # the false positive worth hunting.
    by_title = defaultdict(list)
    for r in unique:
        by_title[(r["title"] or "").lower()].append(r)

    shared = [rs for rs in by_title.values() if len({r["artist"].lower() for r in rs}) > 1]
    shared.sort(key=lambda rs: rs[0]["title"] or "")

    selected, taken = [], set()

    def take(category, candidates):
        for row in candidates:
            key = (row["artist"].lower(), row["title"].lower())
            if key in taken:
                continue
            taken.add(key)
            selected.append(dict(row, category=category))
            if sum(1 for s in selected if s["category"] == category) >= PER_CATEGORY:
                return

    for name, predicate in CATEGORIES:
        matching = [r for r in unique if predicate(r)]
        matching.sort(key=lambda r: (r["artist"] or "").lower())
        take(name, matching)

    for group in shared[:PER_CATEGORY * 3]:
        take("shared_title", group)

    writer = csv.writer(sys.stdout, delimiter=";", quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
    writer.writerow(["title", "artist", "album", "isrc"])
    for row in selected:
        writer.writerow([row["title"], row["artist"], row["album"] or "", row["isrc"] or ""])

    with open("dev/experiments/hard_playlist_categories.json", "w") as f:
        json.dump([{k: r[k] for k in ("title", "artist", "album", "isrc", "category")}
                   for r in selected], f, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Music/Library"))
