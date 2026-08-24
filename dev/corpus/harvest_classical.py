#!/usr/bin/env python3
"""Pick classical recordings out of a local library, spread across composers.

    python3 dev/corpus/harvest_classical.py ~/Music/Library > dev/corpus/classical_sources.json

Classical breaks the matching engine in a way nothing else does, and a sample
that is eight Vivaldi tracks off one album cannot show it. This takes a few per
composer.

What makes the category hard, and what this therefore keeps:

  * The **credit is the composer**, where a catalogue credits the performer.
    Only 16 of 294 classical tracks in this library carry an ISRC, so there is
    no identifier to fall back on either.
  * The **identifying information is inside the title**: a catalogue number
    (`Op. 21`, `BWV 1043`, `RV 269`, `K. 525`) and a movement (`I. Allegro`).
    187 of 294 have the first and 178 the second.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

EXTENSIONS = (".flac", ".mp3", ".m4a", ".ogg", ".wav", ".aiff")

CLASSICAL = re.compile(
    r"\b(op\.|bwv|rv|kv|hob|woo|symphony|concerto|sonata|quartet|prelude|fugue|"
    r"allegro|adagio|andante|nocturne|etude|mass|requiem)\b",
    re.I,
)

PER_COMPOSER = 4


def probe(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=20).stdout
        fmt = json.loads(out).get("format") or {}
        tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
        duration = fmt.get("duration")
        return {
            "artist": tags.get("artist"),
            "title": tags.get("title"),
            "album": tags.get("album"),
            "isrc": (tags.get("isrc") or "").strip() or None,
            "duration_seconds": int(float(duration)) if duration else None,
        }
    except Exception:
        return None


def main(root):
    paths = [os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns
             if n.lower().endswith(EXTENSIONS)]

    with ThreadPoolExecutor(max_workers=16) as pool:
        rows = [r for r in pool.map(probe, paths) if r and r.get("artist") and r.get("title")]

    classical = [r for r in rows
                 if CLASSICAL.search((r["title"] or "") + " " + (r["album"] or ""))]

    by_composer = defaultdict(list)
    for row in classical:
        by_composer[row["artist"]].append(row)

    selected = []
    for composer, tracks in sorted(by_composer.items(), key=lambda kv: -len(kv[1])):
        # Spread across the composer's albums rather than taking one movement
        # after another off a single recording.
        seen_albums, picked = set(), []
        for track in sorted(tracks, key=lambda t: (t["album"] or "", t["title"] or "")):
            if track["album"] in seen_albums and len(picked) >= 2:
                continue
            seen_albums.add(track["album"])
            picked.append(dict(track, composer=composer))
            if len(picked) >= PER_COMPOSER:
                break
        selected.extend(picked)

    json.dump(selected, sys.stdout, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Music/Library"))
