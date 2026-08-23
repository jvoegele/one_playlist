#!/usr/bin/env python3
"""Pick the credit cases out of a local music library.

    python3 dev/corpus/harvest_credits.py ~/Music/Library > dev/corpus/credit_sources.json

Reads tags with ffprobe and keeps only tracks whose *artist credit* has more
than one part — an ampersand, a comma, "and", "with", "feat." — because those
are the ones the matching engine finds hard and a random sample barely
contains. `docs/reference/domain.md` explains why: a collaboration and a
backing band are the same string problem, and only the surrounding evidence
separates them.

Emits **metadata only**. No file paths: they carry a home directory, and this
file is committed to a public repository.

The ISRC is kept and is the point. At replay time it is withheld from the
source, exactly as `match_rate.exs` withholds it, so the identifier rung cannot
answer trivially and the correct candidate is the one carrying that ISRC. A
track without one is still useful — it just has to be judged by a person.
"""

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

EXTENSIONS = (".flac", ".mp3", ".m4a", ".ogg", ".wav", ".aiff")

# The separators that make a credit worth capturing, mirroring
# `OnePlaylist.Matching.Normalize`'s own two lists.
CREDIT = re.compile(
    r"(?:\s&\s|\s\+\s|\s/\s|,\s|\sand\s|\swith\s|\sfeat\.?\s|\sft\.?\s|\sfeaturing\s|\svs\.?\s)",
    re.I,
)

# Kept separately, because a version marker in the title is the *other* half of
# the same problem: a live take and a studio take share a credit exactly.
VERSION = re.compile(
    r"\((?:[^)]*\b(?:live|remix|remaster(?:ed)?|acoustic|demo|edit|version|mix|"
    r"instrumental|single|album|radio)\b[^)]*)\)",
    re.I,
)

# Enough to exercise every category without making the fetch a fifteen-minute
# rate-limited crawl. Raise it when a category looks thin.
PER_CATEGORY = 22

CATEGORIES = [
    ("guest", r"\sfeat\.?\s|\sft\.?\s|\sfeaturing\s"),
    ("ampersand", r"\s&\s"),
    ("with", r"\swith\s"),
    ("and", r"\sand\s"),
    ("listed", r",\s|\s/\s|\s\+\s"),
]


def probe(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True,
            text=True,
            timeout=20,
        ).stdout
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
    paths = [
        os.path.join(directory, name)
        for directory, _, names in os.walk(root)
        for name in names
        if name.lower().endswith(EXTENSIONS)
    ]

    with ThreadPoolExecutor(max_workers=16) as pool:
        rows = [r for r in pool.map(probe, paths) if r and r.get("artist") and r.get("title")]

    # Deduplicate on the credit itself. A library holds the same track on an
    # album and two compilations, and three copies of one case measure nothing.
    seen, unique = set(), []
    for row in rows:
        key = (row["artist"].lower(), row["title"].lower())
        if key not in seen:
            seen.add(key)
            unique.append(row)

    selected, taken = [], set()
    for name, pattern in CATEGORIES:
        matching = [
            r
            for r in unique
            if re.search(pattern, r["artist"], re.I)
            and (r["artist"].lower(), r["title"].lower()) not in taken
        ]
        # Prefer tracks carrying an ISRC: those label themselves.
        matching.sort(key=lambda r: (r["isrc"] is None, r["artist"].lower()))

        for row in matching[:PER_CATEGORY]:
            taken.add((row["artist"].lower(), row["title"].lower()))
            selected.append(dict(row, category=name))

    versions = [
        r
        for r in unique
        if VERSION.search(r["title"] or "")
        and (r["artist"].lower(), r["title"].lower()) not in taken
    ]
    versions.sort(key=lambda r: (r["isrc"] is None, r["artist"].lower()))

    for row in versions[:PER_CATEGORY]:
        selected.append(dict(row, category="version"))

    json.dump(selected, sys.stdout, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Music/Library"))
