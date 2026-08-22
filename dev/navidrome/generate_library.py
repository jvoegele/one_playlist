#!/usr/bin/env python3
"""Build a sample music library for the local Navidrome instance.

Why this exists
---------------

Navidrome indexes files on disk, so a second provider needs a library to serve.
That library has to satisfy two awkward requirements at once:

  * It must **match against TIDAL**, or the cross-provider matching measurement
    it exists to enable is meaningless. Invented titles match nothing.
  * It must contain **no copyrighted audio**, because this repository is public
    and the files would be redistributed with it.

So the audio is synthetic — silent MPEG frames — and the *metadata* is real,
taken from `test/support/fixtures/tidal_isrc_corpus.json`, which was itself
captured from a real TIDAL account. Title, artist, album, ISRC and the true
duration are all genuine; the sound is not. Nobody's recording is copied, and
the resulting library resolves against TIDAL's catalogue exactly as a real one
would.

Duration is reproduced faithfully rather than truncated, because duration
proximity is a real matching signal — `OnePlaylist.Matching.Similarity` uses it
to reject covers and edits, and a library of uniformly 5-second tracks would
quietly disable that rung.

Why not ffmpeg
--------------

It writes MP3 frames and ID3v2.3 tags directly. That is a little more code than
shelling out, and it buys reproducibility: no system package to install, no
version to pin, and it runs the same on a machine where `ffmpeg` is broken —
which is the machine this was written on.

Usage
-----

    python3 dev/navidrome/generate_library.py            # ~30 tracks
    python3 dev/navidrome/generate_library.py --limit 60 # the whole corpus
    python3 dev/navidrome/generate_library.py --no-isrc  # strip ISRCs
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
CORPUS = REPO / "test" / "support" / "fixtures" / "tidal_isrc_corpus.json"
MUSIC = pathlib.Path(__file__).resolve().parent / "music"

# MPEG-1 Layer III, 32 kbps, 44.1 kHz, mono. The lowest bitrate that still
# produces a file every tagger recognises, which keeps a faithful-duration
# library to tens of megabytes rather than hundreds.
FRAME_HEADER = bytes([0xFF, 0xFB, 0x10, 0xC0])
FRAME_BYTES = 144 * 32000 // 44100  # 104
FRAME_SECONDS = 1152 / 44100  # 26.12ms


def silent_mp3(seconds: float) -> bytes:
    """A valid CBR MP3 of the given length, containing silence."""
    frames = max(1, round(seconds / FRAME_SECONDS))
    body = FRAME_HEADER + bytes(FRAME_BYTES - len(FRAME_HEADER))

    return body * frames


def text_frame(frame_id: str, value: str) -> bytes:
    """An ID3v2.3 text frame, UTF-8 encoded."""
    payload = b"\x03" + value.encode("utf-8") + b"\x00"

    # v2.3 frame sizes are plain big-endian, unlike the syncsafe tag size below.
    return frame_id.encode("ascii") + len(payload).to_bytes(4, "big") + b"\x00\x00" + payload


def syncsafe(size: int) -> bytes:
    return bytes(((size >> shift) & 0x7F) for shift in (21, 14, 7, 0))


def id3_tag(frames: bytes) -> bytes:
    return b"ID3" + b"\x03\x00" + b"\x00" + syncsafe(len(frames)) + frames


def safe(name: str) -> str:
    """A filename that survives every filesystem this might run on."""
    cleaned = re.sub(r"[^\w\s.-]", "_", name, flags=re.UNICODE).strip()

    return re.sub(r"\s+", " ", cleaned)[:80] or "untitled"


def build(track: dict, position: int, include_isrc: bool) -> tuple[pathlib.Path, bytes]:
    artist = (track.get("artists") or ["Unknown Artist"])[0]
    album = track.get("album") or "Unknown Album"
    title = track.get("title") or "Untitled"
    duration = track.get("duration_seconds") or 180

    frames = b"".join(
        [
            text_frame("TIT2", title),
            text_frame("TPE1", artist),
            text_frame("TALB", album),
            text_frame("TRCK", str(position)),
        ]
        # TSRC is the ID3 frame for an ISRC. Optional so the library can be
        # rebuilt without them — which is the interesting case, because it is
        # what forces the text and fuzzy rungs to carry the whole match.
        + ([text_frame("TSRC", track["isrc"])] if include_isrc and track.get("isrc") else [])
        + ([text_frame("TPUB", track["album_upc"])] if track.get("album_upc") else [])
    )

    path = MUSIC / safe(artist) / safe(album) / f"{position:02d} - {safe(title)}.mp3"

    return path, id3_tag(frames) + silent_mp3(duration)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=30, help="how many tracks to write")
    parser.add_argument("--no-isrc", action="store_true", help="omit ISRC tags")
    parser.add_argument("--clean", action="store_true", help="empty the library first")
    args = parser.parse_args()

    if not CORPUS.exists():
        print(f"corpus not found: {CORPUS}", file=sys.stderr)
        return 1

    if args.clean and MUSIC.exists():
        # Empties the directory rather than removing it, and that distinction is
        # load-bearing on macOS. `music/` is a Docker bind mount; deleting it
        # leaves the container holding the old, now-unlinked inode, so a
        # recreated directory is **invisible from inside** and every scan finds
        # zero files in about 20ms. Recovering needs a container restart.
        for child in MUSIC.iterdir():
            shutil.rmtree(child) if child.is_dir() else child.unlink()

    rows = json.loads(CORPUS.read_text())
    tracks = [row["source"] for row in rows][: args.limit]

    # Numbered per album so track order is meaningful to a scanner.
    per_album: dict[str, int] = {}
    written = 0

    for track in tracks:
        album = track.get("album") or "Unknown Album"
        per_album[album] = per_album.get(album, 0) + 1

        path, data = build(track, per_album[album], not args.no_isrc)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        written += 1

    total = sum(f.stat().st_size for f in MUSIC.rglob("*.mp3"))

    print(f"wrote {written} tracks to {MUSIC}")
    print(f"  albums: {len(per_album)}")
    print(f"  ISRCs:  {'omitted' if args.no_isrc else 'included'}")
    print(f"  size:   {total / 1_048_576:.1f} MB")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
