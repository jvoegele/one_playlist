# Reference: The Playlist-Transfer Domain

Competitive landscape (Soundiiz, TuneMyMusic, and the rest), the technical core of the
problem (track matching), and the hard constraints imposed by the music platforms' APIs.

---

## 1. What the incumbents do

### Soundiiz — the feature leader

Tiers (as of 2026): **Free** $0 · **Premium** $39/yr ($5/mo) · **Creator** $75/yr ($9.50/mo).

| Feature | Free | Premium | Creator |
| --- | --- | --- | --- |
| Playlist transfer | one at a time, **≤ 200 tracks** | unlimited | unlimited |
| Batch operations | — | ✓ | ✓ |
| Albums / artists / liked-tracks transfer | — | ✓ | ✓ |
| **Sync slots** (auto-sync pairs) | 1 | 20 | 50 (purchasable) |
| Export formats | — | CSV, TXT, XSPF, JSON, XML, URL | same |
| AI playlist generation | ≤ 20 / 24 h | ≤ 20 / 24 h | ≤ 20 / 24 h |
| Smartlinks analytics | — | standard | advanced + subdomain, no attribution |
| Priority support | — | ✓ | ✓ |

Capabilities:
- **Transfer** playlists, albums, artists, and liked/saved tracks between ~45 services.
- **Auto-sync**: keep a playlist mirrored across two platforms on a daily / weekly / monthly
  schedule. This is the retention feature; the sync-slot count is the pricing lever.
- **Import/export**: M3U, XSPF, iTunes XML, CSV, plain text, and web URLs in; CSV, TXT, XSPF,
  JSON, XML out.
- **Playlist tools**: sort, merge, split into parts, shuffle, clone, dedupe, create.
- **AI generation** of playlists / album lists / artist lists.
- **Smartlinks** — a curator-facing promotional landing page for a release or playlist.
- Long tail of platforms is a genuine moat: Plex, Jellyfin, Emby, Navidrome, Subsonic,
  Bandcamp, Beatport, SoundCloud, Pandora — plus per-platform read/write capability matrices.

#### How their sync actually works, and why it matters to us

Worth stating precisely, because it is a solved design we should adopt rather than reinvent,
and because one of its constraints is one we hit independently.

A sync slot pairs **one source playlist with one destination playlist**, and runs in **one
direction**. It is not a bidirectional mirror. Frequency is daily, weekly or monthly. Two update
methods:

| Method | What it does | Source removals | Destination-only tracks |
| --- | --- | --- | --- |
| **Add** | Appends matched source tracks not already at the destination | **Not** propagated | Kept |
| **Replace** | Rewrites the destination from the source | Propagated | **Removed** |

Add checks the destination before writing, so it does not duplicate — the same snapshot-and-diff
this project's `Runner` already does.

**Replace is not available on every platform, and this is the interesting part.** Deleting a
track from a playlist is an API capability some services simply do not offer; Apple Music
withdrew its delete methods, so Soundiiz answers a Replace sync there with a "feature not
available for this platform" error rather than silently doing something else.

Two consequences for us:

  * **Add-mode sync needs no capability we do not already have.** It is the existing transfer on
    a schedule, and it works against every provider. Replace needs deletion, and therefore needs
    the capability model below before it can be offered at all.
  * **`OnePlaylist.Providers.Adapter` currently assumes every provider can do everything.** It
    has `add_tracks/4` and no counterpart, which is what forced match override to be offered on
    unmatched rows only — correcting a row that already matched would leave the wrong track in
    the playlist with no way to remove it. The incumbent has the same underlying limitation and
    models it explicitly as a per-platform capability. We should too: a
    `capabilities/0` on the adapter behaviour, consulted by the UI and by the sync scheduler, so
    that "this service cannot do that" is a fact the code carries rather than a surprise at the
    call site.

*(Sourced from Soundiiz's public feature and sync pages plus search summaries of their help
centre — `support.soundiiz.com` refuses automated requests, so the help articles themselves were
not read directly. Treat the table above as their documented behaviour, not as verified
behaviour.)*

### TuneMyMusic — the simpler, cheaper one

- ~20+ platforms, entirely browser-based, no install.
- **Free: 500 songs per transfer.** Paid removes the cap.
- Paid unlocks **auto-sync** (mirrors changes, up to 20 times/day), AI playlist creation,
  cloud backups, and universal share links.
- Pricing around $5.50/mo monthly or ~$2/mo billed annually — materially cheaper than Soundiiz.

### The rest of the field

FreeYourMusic (desktop/mobile apps, one-time purchase option), PlaylistGo, Tunarc, Tuneferry,
Paradify, MusicAPI.com (a B2B "universal music API" — worth studying as a competitor *and* as
a possible dependency).

### Where the differentiation is

Both leaders converge on the same feature set, which tells you where the real competition is:

1. **Match quality.** The loudest, most common complaint about every one of these tools is
   wrong matches — a karaoke version, a cover, a live take, the wrong "feat." credit, or a
   silent drop. Tools advertising ISRC-based matching claim ~97–99.2% match rates against
   text-only matching. **This is the product.**
2. **Transparency about what didn't transfer.** A per-track report with the reason, and a
   manual "pick the right one" resolution UI, is worth more than another platform integration.
3. **Sync reliability.** Auto-sync is the subscription hook; it lives or dies on OAuth token
   refresh, rate-limit discipline, and idempotency — exactly what `external_service` is for.
4. **The long tail of platforms**, especially self-hosted (Plex/Jellyfin/Navidrome/Subsonic),
   where the incumbents' coverage is thin and the users are technical and vocal.

---

## 2. The technical core: track matching

The whole problem reduces to: *given a track on service A, find the same recording on
service B.*

### Matching ladder (best to worst)

1. **ISRC** (International Standard Recording Code) — globally unique per *recording*. Spotify
   and Apple Music both expose it on tracks; Tidal and Deezer do too. An ISRC match is an
   exact-recording match, not a guess. This should be the first pass, always.
2. **UPC / EAN** at the album level, then position within the album — recovers tracks whose
   ISRC is missing or differs across territorial releases.
3. **Normalized text match**: artist + title + album, after normalization (case-fold, strip
   diacritics, strip `(Remastered 2011)` / `(Deluxe Edition)` / `- Live` suffixes, normalize
   `feat.` / `ft.` / `&` / `and`, unify Unicode dashes and quotes).
4. **Duration proximity** as a tiebreaker (±2–3 s) — the single cheapest signal for rejecting
   covers, edits, and karaoke versions.
5. **Fuzzy string similarity** (Jaro-Winkler / token-set ratio) with a confidence threshold.
6. **Semantic / embedding similarity** (pgvector) as a last resort.

### Failure modes to design for explicitly

- Same recording, different ISRC per territory or per re-release.
- Regional licensing: the track exists but is unavailable in the user's market.
- Remasters, deluxe editions, radio edits, explicit vs clean.
- Live albums and compilations where the recording genuinely differs.
- Classical and jazz, where "artist" is ambiguous (composer vs performer vs ensemble).
- Local files, podcasts, and user uploads that simply have no counterpart.
- Duplicate candidates that all match — pick deterministically and record why.

### Design implications

- **Never silently drop a track.** Every unmatched track gets a typed Errata error carrying
  the source metadata, the candidates considered, and the confidence — surfaced in a report
  and resolvable by hand.
- Model match confidence as a first-class value (`:exact_isrc`, `:exact_upc`, `:high`,
  `:medium`, `:low`, `:none`), let the user set a threshold, and let them review the middle.
- Cache resolutions: `(source_service, source_id) → (dest_service, dest_id, confidence)` is
  reusable across every user and is the asset that compounds. Consider MusicBrainz as a
  cross-service identity spine.
- Idempotency matters more than throughput: a retried "add tracks" call must not duplicate.
  Snapshot the destination, diff, and add only what's missing.

---

## 3. Platform API constraints (the real gating factor)

> **Read this before promising any user-facing scope.** The APIs, not the code, are what
> makes this product hard to ship to real users.

### Spotify — severe

- **New apps start in Development Mode: at most 5 authenticated users, each manually
  allowlisted, and the app owner must have Spotify Premium.**
- **Extended Quota Mode, as of May 2025, requires: an organization (not an individual), legal
  business registration, an actively launched service, and ≥ 250,000 monthly active users.**
  Review takes up to six weeks.
- Rate limits are computed over a rolling **30-second window** and vary by mode; exceeding
  them returns `429` with a `Retry-After` header that must be honoured (values can be large).
  A few endpoints (e.g. playlist image upload) have their own separate limits.
- Consequence: **`one_playlist` cannot be a public Spotify-backed service.** It can be a
  personal/small-group tool (≤ 5 allowlisted users), and any "real users" ambition must either
  route through a partner with extended quota, or lead with non-Spotify platforms.

### YouTube Music (via YouTube Data API v3) — severe

- Default quota: **10,000 units/day per Google Cloud project**, resetting at midnight Pacific.
- `playlistItems.insert` costs **50 units** → **~200 track adds per day, total, across all
  users.** `search.list` costs 100 units, so text-search-based matching is even worse.
- Quota increases require a Google audit.
- Consequence: YouTube Music support is only viable with aggressive caching, ISRC-free
  matching strategies that avoid `search.list`, and per-user Google Cloud projects (or an
  approved quota increase).

### Apple Music (MusicKit) — moderate

- Requires an **Apple Developer Program** membership ($99/yr) and a MusicKit private key
  (`.p8`), from which you mint a **developer token** (an ES256 JWT, max 6 months).
- A **Music User Token** (`music-user-token` header) is additionally required for anything
  touching a user's library, and is obtained through MusicKit JS (web) or MusicKit on Apple
  platforms — i.e. a browser-side step you cannot do purely server-side.
- Catalog endpoints (`/v1/catalog/*`) are server-cached and rarely rate-limited; **library
  endpoints (`/v1/me/library/*`) are per-user and are the ones that hit limits.**
- Adding to a *library playlist* is supported; capabilities are narrower than Spotify's.

### Tidal — good, and the platform this project builds on first

- Unified JSON:API at `openapi.tidal.com/v2`: catalog, search, recommendations, playlists,
  user collections, playback manifests.
- Full playlist CRUD including reorder, items, cover art, owners — with `playlists.read` /
  `playlists.write` scopes.
- Currently the friendliest major platform for a small developer.

**Verified against the live service, 2026-08-22** (not taken from documentation, which is
JS-rendered and awkward to read):

| | |
| --- | --- |
| API base | `https://openapi.tidal.com/v2` |
| Authorize | `https://login.tidal.com/authorize` |
| Token | `https://auth.tidal.com/v1/oauth2/token` (form-encoded) |
| Flow | Authorization Code + **PKCE (S256)**; private playlists and `/me` work *only* under PKCE |
| Scopes | `user.read`, `collection.read/write`, `playlists.read/write`, `playback`, `recommendations.read`, `search.read/write`, `entitlements.read` |

API errors are JSON:API shaped:

```json
{"errors": [{"code": "UNAUTHORIZED",
             "detail": "Invalid or missing Authorization Header",
             "meta": {"category": "AUTHENTICATION_ERROR"}}]}
```

Token errors are standard OAuth 2.0 plus Tidal's own status fields:

```json
{"error": "invalid_grant", "error_description": "Token has invalid payload",
 "status": 400, "sub_status": 1005}
```

**Verified against a real account, 2026-08-22** (OAuth round trip completed, 216 playlists read):

- `GET /users/me` → `data.attributes` has `country`, `developerAccessTier`, `email`,
  `emailVerified`, `firstName`, `lastName`, `username`. **`username` may be the email** — it
  was for the test account. `country` here is the `countryCode` other endpoints want, and it
  also appears as `cc` inside the access token's JWT payload.
- **`me` is not a valid path segment outside `/users/me`.** Listing playlists needs the numeric
  account id:

  | Path | Result |
  | --- | --- |
  | `/userCollections/{id}/relationships/playlists` | **200** |
  | `/userCollections/me/relationships/playlists` | 404 `NOT_FOUND` |
  | `/users/{id}/relationships/playlists` | 404 |
  | `/playlists?filter[r.owners.id]={id}&countryCode=US` | **200** |

- The relationships endpoint returns **identifiers only** — `{"id", "type", "meta.addedAt"}` —
  not playlist names. Getting titles needs either `include=`, a follow-up `/playlists/{id}`, or
  the `filter[r.owners.id]` form, which returns full resources. Worth settling before building
  the playlist list UI, since it is the difference between one request and 216.
- Pagination is `links.next` (a path plus `page[cursor]`) with the cursor also in
  `links.meta.nextCursor`. Pages were 20 items.

**Verified against a real account, 2026-08-22** (the matching engine's requirements):

| Request | Result |
| --- | --- |
| `/tracks?filter[isrc]={isrc}&include=artists,albums` | **200** — the ISRC rung as a direct lookup |
| `/searchResults?filter[query]={q}&include=tracks.artists,tracks.albums` | **200** — text search |
| `/searchResults/{query}` (8 variants tried) | 400 `INVALID_RESOURCE_ID` — see below |

- **`filter[isrc]` is the whole first rung of the ladder**, in one request, with exact results
  and no text scoring. It is cheaper *and* better than search, and it should be the first thing
  looked for on any new provider.
- **Expect several results per ISRC.** `GBAYE0601477` returned two entries; across a 60-track
  sample, 40 tracks resolved to more than one candidate and one resolved to twenty. The same
  recording appears on a single, an album and any number of compilations, each its own
  catalogue entry. Ambiguity is the normal case, not the exotic one — a matcher that takes the
  first result is wrong most of the time it matters.
- **Text search is a filtered collection, not a resource addressed by the query.** This cost
  eight request variants to find, because every wrong one returns the same
  `400 INVALID_RESOURCE_ID`, which names neither the offending parameter nor the reason.

  | Request | Result |
  | --- | --- |
  | `/searchResults?filter[query]=hey+jude` | **200** |
  | `/searchResults?query=hey+jude` | 400 `MISSING_REQUIRED_PARAMETER`, "At least one filter is required" |
  | `/searchResults/hey%20jude` | 400 `INVALID_RESOURCE_ID` |

  The path form is not wrong in general — it is what the response's own `links.next` uses — but
  it takes the **opaque search id** from `data[0].id`, not the query text. That is the whole
  explanation, and the error message points at none of it. Only the `?query=` spelling produced
  a diagnostic that helped, and only because it was wrong in a different way.

  > A hypothesis recorded here earlier — that the failures were caused by the missing
  > `search.read` scope — was **wrong**. The scope really was missing and really is required,
  > but granting it changed nothing: the path form still returns `INVALID_RESOURCE_ID`. Two
  > independent problems presenting as one error code, which is what made it plausible.

- **The response shape is doubly indirect.** `data` holds one `searchResults` resource whose
  attributes are just `{query, trackingId}`; the tracks it found are identified by
  `data[0].relationships.tracks.data`, in relevance order, and their resources are in
  `included`.
- **`include=tracks` alone is not enough.** The included tracks then arrive with **no
  relationships at all**, so no artist names and no album barcode — a candidate that cannot be
  scored on text. `include=tracks.artists,tracks.albums` is the form to use: one request
  returned 20 tracks, 17 albums and 5 artists.
- **Track attributes** are `accessType, availability, copyright, createdAt, duration, explicit,
  externalLinks, isrc, mediaTags, popularity, spotlighted, title, version`. Two matter for
  matching: `version` carries `"Remastered 2015"` as a structured field rather than in the
  title, and `popularity` is a deterministic tiebreaker between otherwise identical candidates.
- **Album attributes** include `barcodeId` (the UPC/EAN), available for free when albums are
  already included. TIDAL reports it zero-padded to 13 digits (`"00602547670052"`) where other
  catalogues print 12 — so barcodes must have leading zeros stripped before comparison.
- **The track's position within its album is not available** from the track resource or from
  the `albums` relationship, which carries only `{id, type}`. It comes from a separate request,
  and the next two facts are what make rung 2 workable anyway.

- **Albums are findable by barcode.** `GET /v2/albums?filter[barcodeId]={upc}` returns the
  release. That turns a UPC from a mere corroborating signal into a **lookup**: given a source
  that knows its barcode and its position — which Spotify and Apple Music both supply natively
  — the destination track is two requests away and the answer is exact rather than scored.

  Not every barcode resolves. One album in an eight-track live sample reported a `barcodeId`
  that `filter[barcodeId]` then did not find, so the path must fall back to text search rather
  than treat a miss as an absence.

- **Album items carry explicit positions.** `GET /v2/albums/{id}/relationships/items` returns
  each item with `meta: {trackNumber, volumeNumber}`.

  > This is the difference between rung 2 being sound and being dangerous. The positions are
  > **given**, not inferred from list order — and inferring them would be wrong, because a
  > track unavailable in the account's country is listed while its resource is withheld,
  > exactly as on playlists. Counting by index would renumber every track after such a gap, and
  > a multi-volume release would renumber wholesale, since disc 2 restarts at track 1. Rung 2
  > would then match at score `1.0` — above any review threshold — to the wrong recording.

  `include=items.artists` costs nothing extra and makes the results scoreable on text too, so a
  candidate rung 2 declines is not wasted.

- **A barcode's album id is worth caching across users, nodes and deploys.** It is identical
  for every user and does not change through normal catalogue drift, which makes it the
  compounding asset described above rather than per-user state. Tracks cluster into albums
  (38 distinct albums across the 60-track corpus; 8 across a 12-track live sample), so caching
  removes most of the lookups outright.

  Measured live over 8 distinct barcodes:

  | | Time |
  | --- | --- |
  | Cold — both tiers empty, 8 calls to TIDAL | **2,503 ms** |
  | Warm L1 (in memory) | **0 ms** |
  | After a deploy — L1 gone, L2 intact | **13 ms** |

  The last row is the entire argument for persisting it. A restart without L2 costs the full
  2,503 ms *and* 8 requests against an unpublished quota; with L2 it costs 13 ms and none.

  Worth being explicit about the alternative, because the instinct is to reach for concurrency:
  running these requests in parallel reduces wall-clock while spending **exactly the same
  quota**, and the circuit breaker is shared across all users, so bursting catalogue reads
  degrades TIDAL for everyone. Fewer requests is the lever; faster requests is not. The same
  reasoning makes request coalescing worth building — without it, N concurrent misses on one
  barcode are N identical requests, arriving precisely when the system is busiest.

  One caveat on permanence: the *release* a barcode names is permanent, but a provider's **id**
  for that release need not be — a re-ingest or a delisting can change it, and the only symptom
  is a 404 on the follow-up request. So a cached id is invalidated where that 404 is seen
  rather than trusted indefinitely.

**Verified against a real account, 2026-08-22** (the write path):

| Request | Result |
| --- | --- |
| `POST /v2/playlists` + `{data: {type, attributes: {name, description}}}` | **201**, `data.id` is a **UUID** |
| …with `attributes.accessType: "PRIVATE"` | 400 `INVALID_REQUEST_BODY`, pointer `data/attributes/accessType` |
| …with `"UNLISTED"` or `"PUBLIC"` | **201** |
| `POST /v2/playlists/{id}/relationships/items` + `{data: [{id, type: "tracks"}]}` | **200** |
| `DELETE /v2/playlists/{id}` | **200** |
| `DELETE /…/relationships/items` + `{data: [{id, type: "tracks"}]}` | 400 `Must not be null` |
| …with `{data: [{id: <itemId>, type: "tracks"}]}` | 400 `Must not be null` |
| …with `{data: [{id, type: "tracks", meta: {itemId}}]}` | **200** *(2026-08-24)* |

- **A created playlist's id is a UUID**, where every catalogue id is numeric. Nothing should
  assume a shape for a provider id.
- **`accessType` is best omitted.** `"PRIVATE"` is rejected outright, so the safe default is to
  let TIDAL choose rather than guess at a visibility on someone's library.
- **An append does not deduplicate.** TIDAL will add a track already present, as many times as
  asked. Idempotency is the caller's job, which is why a transfer must snapshot the destination
  and diff before writing.
- Items read back carry `meta.itemId` — a per-item UUID distinct from the track id — which is
  what makes removing one *occurrence* of a duplicated track possible.
- **A removal needs both ids and says so badly.** Verified 2026-08-24: the track id alone and
  the item id alone are each a 400 whose message is `Must not be null`, naming neither field.
  Only the pair works, and it removes precisely the entry whose `itemId` was given — a second
  copy of the same track is left in place. So a caller cannot remove by track id: it has to
  read the playlist first, which is why `c:OnePlaylist.Providers.Adapter.remove_tracks/4` takes
  tracks and resolves them per adapter rather than taking ids.

> #### Mutations are rate-limited far harder than reads {: .warning}
>
> This corrects what is written above from community reports. Measured: **five playlist deletes
> issued back to back returned one 200 and four 429s.** Re-issued two seconds apart, all four
> succeeded first time.
>
> So "429s are common on catalog reads and rare on playlist operations" is not true for bursts,
> and a bulk transfer is nothing but a burst. Writes need their own limiter an order of
> magnitude below the read one — see `OnePlaylist.Providers.Tidal.WriteService` — and their own
> circuit breaker, so a transfer melting the write path does not take library browsing with it.

**Rate limits are not published.** Community reports put 429s as common on catalog reads and
rare on playlist operations. With no documented quota the only safe posture is to stay well
under whatever it is — hence the deliberately conservative 8 calls/second in
`OnePlaylist.Providers.Tidal.Service`.

Tidal is **not** one of Supabase Auth's built-in social providers, so its OAuth flow is driven
by this application rather than by GoTrue. That is more code and a better outcome: the tokens
arrive directly instead of appearing once in a Supabase session and vanishing.

### Navidrome / Subsonic — the second provider, and the differently-shaped one

Self-hosted, free, unlimited, and **nothing like TIDAL** — which is why it is provider #2 rather
than Spotify. An adapter behaviour derived from one provider is a guess until a second one
disagrees with it.

Run locally with `dev/navidrome/docker-compose.yml`; the sample library is generated by
`dev/navidrome/generate_library.py` (synthetic audio, real metadata — see its docstring).

**Verified against Navidrome 0.58.0, 2026-08-22:**

| | |
| --- | --- |
| API | Subsonic 1.16.1 (`/rest/*`), with OpenSubsonic extensions |
| Auth | `u` + `t` + `s`, where `t = md5(password <> salt)` and `s` is a per-request salt |
| Response | everything wrapped in `subsonic-response`; `f=json` to avoid XML |
| Errors | `status: "failed"` plus `error: {code, message}` — **HTTP 200 regardless** |

Every axis on which it differs from TIDAL is a place the adapter behaviour could have encoded
one provider's assumptions:

| | TIDAL | Subsonic |
| --- | --- | --- |
| Auth | OAuth 2 + PKCE, refresh tokens, expiry | username + salted MD5, **no expiry, nothing to refresh** |
| Shape | JSON:API — `data`, `included`, relationships | flat query params, flat JSON |
| Failure | HTTP status codes | always 200; read `error.code` |
| Paging | opaque cursor in `links.next` | `offset` / `size` |
| ISRC | scalar string on the track | **array** — `"isrc": ["DESK90390301"]` |
| Rate limit | unpublished, mutations throttled hard | none — it is your own server |

The auth row is the one that matters most for design. `OnePlaylist.Providers.Connection` was
built around OAuth: `access_token`, `refresh_token`, `access_token_expires_at`, proactive
refresh. A Subsonic connection has a server URL, a username and a password, and nothing ever
expires — so it is the first real test of whether that schema describes *provider
authorization* or merely *OAuth*.

**Playlist CRUD is complete and verified:**

| Call | Notes |
| --- | --- |
| `search3?query=…` | one call for songs, albums and artists; an empty query returns everything |
| `createPlaylist?name=…&songId=…` | `songId` repeated per track; returns the playlist |
| `updatePlaylist?playlistId=…&songIdToAdd=…` | appends |
| `updatePlaylist?playlistId=…&songIndexToRemove=…` | removes **by position**, zero-based |
| `getPlaylist?id=…` | entries in order |
| `deletePlaylist?id=…` | |

**Removal is by index, and there is no song id in it at all.** Verified against Navidrome
0.58.0 on 2026-08-24: `songIndexToRemove` is zero-based, may repeat, and every index is read
against the list as it stood *before* the call — removing 0 and 2 from four entries leaves the
second and fourth rather than shifting under its own feet. The consequence is the same one
TIDAL arrives at from the opposite direction: an entry is named by something only a fresh read
can supply, so a stale index silently removes the wrong track rather than failing. Whatever
computes these must have read the playlist in the same breath.

Two consequences worth carrying into the adapter. There is no ISRC *filter* — `search3` is text
only — so the ISRC rung has to be served by searching and then comparing, which is the first
provider where rung 1 is not a direct lookup. And a real self-hosted library usually has **no
ISRCs at all**, because they come from tagging rather than from a catalogue; the generated
library can be rebuilt without them (`--no-isrc`) precisely so the text and fuzzy rungs can be
measured carrying the whole match.

### Playlist files — what a real exporter actually writes

Learned from two Roon exports of the same 58-track playlist, 2026-08-23. Both are committed in
trimmed form as `test/fixtures/roon_export.csv`; the reasoning is here because every item cost
something to discover.

| | What Roon writes |
| --- | --- |
| CSV separator | **`;`**, not `,` |
| CSV header | `title;artist;album;isrc` — singular `artist` |
| ISRC case | **lower** — `ussm10805339` |
| Line endings | LF, no BOM |
| Versions | in the title: `(Remastered)`, `(Live)`, `(Album Version)`, `(Brendan O'Brien Mix)` |
| Duration | **absent entirely** |
| XLSX columns | `Album Artist, Album, Disc#, Track#, Title, Track Artist(s), Composer(s), External Id, Source, Is Dup?, Is Hidden?, Tags, Path` |

Four of those changed the code.

**The separator is the one that mattered.** Read as comma-separated, the entire header is a
single unrecognised column and the file is rejected outright — a total failure on the first real
file we were handed. `;` is not a Roon quirk either: a spreadsheet saved as "CSV" in a European
locale uses it, because `,` is the decimal point there. `OnePlaylist.Formats.Csv` now picks the
separator that turns the header into the most column names it recognises, among `,`, `;` and tab.
That is not sniffing content — it is choosing the reading under which the file has a header we
understand, and a file none of them explains is rejected exactly as before.

**Lower-case ISRCs were already handled, by luck rather than design.** Rung 1 compares for exact
equality, so raw comparison would have silently killed the most trusted rung for every imported
track. `Strategy.Isrc.normalize/1` upcases before comparing, so it works — and the codec
deliberately stores what the file said, matching what the TIDAL and Subsonic mappers do. Pinned
by a test now, because it held by accident.

**Versions in the title are the right shape for the existing engine.** Roon has no version
field, so `Rearviewmirror (Remastered)` arrives as one string —
`OnePlaylist.Matching.Normalize` already takes titles apart and classifies `remaster` and
`album version` as *editorial* (same performance, soft signal) while `live` is *discriminating*
(different recording, vetoes). Nothing needed changing, which is worth recording as a
confirmation rather than a non-event.

**No duration at all**, so `duration_conflict` can never fire on a Roon import — the veto added
after the MusicBrainz measurement is inert on exactly the input that most needs discrimination.
This is the concrete form of the metadata problem: rung 1 works only where an ISRC is present
(57 of 58 here), and everything else falls to text with no length to check it against.

**The XLSX has more columns and is the worse import.** Both exports of the same 58-track
playlist, counted:

| | CSV | XLSX |
| --- | --- | --- |
| **ISRC** | **57 / 58** | **0 / 58** — no such column |
| Disc# / Track# | absent | 58 / 58 |
| `Track Artist(s)` | — | 38 / 58 |
| `External Id` | — | 34 / 58, all `rovi:MT…` |
| `Path` | — | 34 / 58 |
| `Source` | — | 34 `Local`, 24 `Tidal` |

No ISRC column exists in the spreadsheet at all, so rung 1 goes from resolving 57 of 58 tracks
exactly to resolving none. Everything falls to text, on a file that also has no duration — so
the `duration_conflict` veto cannot fire either.

`External Id` looked like it might overturn that and does not: it is a **Rovi/AllMusic**
identifier, present only on the 34 `Local` rows. The 24 TIDAL-sourced rows have it empty, so
there is no id to look a streaming track up by, and importing a Roon playlist into TIDAL is a
matching problem either way.

**So spreadsheets are deliberately not supported.** Reading them would mean a zip and an XML
parser on user uploads — decompression bombs and entity expansion are real on that path — in
order to import the weaker of two files the user already has. `parse/2` detects the
`PK\x03\x04` magic and says so, naming the ISRC as the reason rather than only the remedy.

Two things that would change the answer, neither true yet: a **path-based import** for
self-hosted libraries could use `Path` + `Source: Local` — though M3U is the standard for that
and far simpler, so it comes first; and people who keep playlists in **Excel** with no CSV to
export are a real audience, unlike Roon users, who have one.

The XLSX column names *are* aliased for CSV, because Roon → XLSX → Excel → "Save as CSV" is a
likely route in.

`Album Artist` is deliberately **not** aliased to artists. On a compilation it is "Various
Artists", which performs nothing on the album — and a wrong artist is worse than none here,
because the text rung needs `artists_agree`, so a confident wrong value rejects the right
candidate where an absent one would have let the title carry the match.

### An ISRC miss is not an answer — reissues carry new codes

Recorded because the opposite was believed here, written down as a reason, and acted on for
weeks before a real import disproved it.

An ISRC identifies a recording **as issued on a particular release**. A reissue, remaster or
compilation appearance is a new issue and gets a **new ISRC** for the same master. So "the
destination's catalogue does not contain ISRC X" does *not* mean "the destination does not have
that recording".

Measured, on a 153-track Roon export:

| | |
| --- | --- |
| Roon's ISRC for Eddie Vedder's *Setting Forth* | `USJY50700001` — the 2007 *Into the Wild* soundtrack |
| TIDAL's ISRC for the same recording | `USJY51700100` — the 2017 reissue |
| `filter[isrc]=USJY50700001` on TIDAL | **0 results** |
| `filter[query]=Setting Forth Eddie Vedder` | 20 results, the right one first |

`Tidal.candidates/3` used to stop on an empty ISRC result, so the track was reported *"nothing
found on the destination"* while sitting in the catalogue under a different number. Four tracks
of that playlist — the whole soundtrack block — failed this way. Falling back to text recovers
all four at `high` confidence, and moves a fifth from "nothing found" to a list of candidates
worth choosing between.

The fear that motivated the old rule (text search finding a *different* recording and reporting
it as a match) is real, and is defended by the version veto, the duration conflict and the
confidence threshold — every text candidate goes through all three. Refusing to look was never
what made the answer safe; it only made a findable track unfindable.

**The general lesson**: an identifier rung's miss is evidence about the *identifier*, not about
the recording. Treat it as a reason to try the next rung, never as an answer.

### The text rung is a gate, and its corroboration cannot decline a match

The most important structural fact about the matching engine, learned from a false positive
rather than from reading it.

`Strategy.Text` is **gate, then corroborate**: `title_exact and artists_agree and not vetoed and
not duration_conflict` opens the gate, and duration, album, barcode and editorial signals then
place the score inside the rung's band. That band is `0.80`–`0.98`, and the default threshold is
`:medium` — **0.75**. So the *lowest* score the rung can return is above the threshold, and
passing the gate is the same thing as matching. Corroboration only chooses how confident the
answer sounds.

Every safety property therefore lives in the gate. A comment in the tests once said a permissive
artist rule was safe "because duration and album still have to corroborate" — they cannot, and
had not for as long as the comment existed.

This is also why the two fixes the measurement produced were both *gates*:
`duration_conflict` (Kraftwerk's "Neonlicht", 535s against 344s) and the credit rule below. When
this rung has doubt, the only thing it can do with it is decline and let `Fuzzy` — whose band is
`0.0`–`0.79` and which therefore *can* fall below a threshold — score the candidate instead.

**Before adding a signal to the corroboration, ask whether it needs to be a gate.** A signal that
should be able to prevent a match cannot do it from there.

### An ambiguous credit raises the bar; it does not decide the match

A live "Powderfinger" credited to *Neil Young & Pearl Jam* matched the studio recording on *Rust
Never Sleeps*, credited to *Neil Young* alone, and landed in a Pearl Jam playlist at `medium`.

The gate accepted a subset in either direction over a flat set of every name — and
`Normalize.artists/1` builds that set by splitting on `,&/+` and on
`x|and|feat|ft|featuring|with|vs` alike, so the conjunction is gone before anything compares
them.

**The trap is that the obvious fix is wrong.** Requiring the credits to match exactly rejects
*Neil Young & Crazy Horse* against *Neil Young*, which is one recording credited two ways.
And no rule over the strings can tell those cases apart:

| | source vs candidate | artist similarity |
| --- | --- | --- |
| A collaboration | Neil Young & Pearl Jam · Neil Young | **0.667** |
| A backing band | Neil Young & Crazy Horse · Neil Young | **0.667** |

Identical. The difference is world knowledge — Pearl Jam is a headline act, Crazy Horse is a
backing band — and nothing in the metadata carries it. Strict equality was measured and cost two
corpus tracks while fixing nothing that the rule below does not.

Nor can another field decide it. Album similarity for the bad match was **0.53**, *higher* than
the **0.50** of a legitimate *Vitalogy* against *Rearviewmirror: Greatest Hits* pairing.

So `Signals.credit_match/4` reports the *relationship* rather than a verdict, and
`Strategy.Text` decides what evidence each one has to earn:

| Relationship | Meaning | What the rung asks for |
| --- | --- | --- |
| `:same` | equal primary credits, or names that scramble into each other | nothing — the normal path |
| `:contained` | one primary set strictly inside the other | **one independent field agreeing at ≥ 0.9** — duration, barcode or album |
| `:unrelated` | disjoint, partial overlap, or empty | refused outright |

`Normalize.credits/1` keeps the distinction that flattening destroys, so a backing band reaches
`:same` rather than needing corroboration at all: "X and *the* Ys" is one act, "X & Y" is two,
and the definite article is the marker. That is why `Normalize.text/1` keeping leading articles
is load-bearing rather than incidental.

What this buys:

  * *Neil Young & Crazy Horse* on the same album at the same length — **matches**, because
    everything except the credit agrees.
  * The same pair with nothing but a title and a partial credit — **declines**, correctly. There
    is no evidence either way, and this rung cannot express doubt.
  * *Neil Young & Pearl Jam* against a studio take on a different album with no duration —
    **declines**.
  * *Bruce Springsteen and the E Street Band* against *Bruce Springsteen* — matches with no
    corroboration needed, because the credits are `:same`.

Measured on the hundred-track corpus: identical to the baseline in every bucket — `certain` 82,
`duration_corroborated` 12, `none` 5, wrong 1. The strict-equality version moved two tracks; this
moves none.

**The general shape, worth reaching for again**: when two cases are genuinely indistinguishable
from the evidence, do not pick a side. Make the ambiguous one carry a higher burden of proof, and
let the absence of proof be the answer.

### The credit corpus, and what it found

`dev/corpus/` holds 120 cases harvested from a real library and filtered to the credits the
engine finds hard. `test/one_playlist/matching/credit_cases_test.exs` replays them on every
`mix test`; `dev/corpus/replay_credit_cases.exs` prints the breakdown.

Current standing: **94 correct, 11 equivalent, 10 missed, 0 wrong** of 115 judged, and **5 of 5**
hand-labelled decline cases correctly declined.

  * `equivalent` is the `duration_corroborated` allowance under another name: the engine chose a
    different release of the same recording, within three seconds and the same normalized title.
    Prince's *Purple Rain* forced it — the engine's pick is one second from the source and the
    ISRC-labelled answer is seven.
  * The 10 misses are the backlog. **Six share one cause**: the source's version marker lives in
    its *album* — *At Folsom Prison*, *Live at Leeds* — and the veto only reads version tags out
    of the **title**, so a correctly-labelled live candidate is refused by a source that is
    equally live. That is the same root as the Powderfinger false positive from the other
    direction, where the source's liveness being album-borne meant nothing caught the mismatch.

Two methodological things this corpus taught, both of which cost a wrong answer first:

  * **A review sheet must show every candidate.** An earlier one showed five of ten and asked
    "is any of these right"; the replay then scored the engine against that answer using all ten.
    One label said "none of these" about a list that did not contain the answer.
  * **An ISRC oracle can only produce should-match cases.** It says which candidate is right,
    never that none is — so a corpus built from it is structurally blind to a false positive.
    Only hand-written `decline` labels catch those, and they are the reason this corpus can
    defend against the bug that motivated it.

### Rejected: a strong release agreement overriding the version veto

Recorded because the idea is a good one, the measurement supported it, and it is still wrong.

Johnny Cash's "Jackson" is missed. The source is from *At Folsom Prison*; TIDAL titles the same
recording "Jackson (with June Carter Cash)" with the version "Live at Folsom State Prison". The
veto sees a live marker on one side and nothing on the other and refuses — while the albums agree
at 0.90 and the durations are two seconds apart. The source is *equally live*; its liveness lives
in the album name, where the veto cannot see it.

The proposed rule: a version marker stops being evidence of a different recording once the
releases agree, because **a release does not carry two different recordings under one title**.

Measured: the credit corpus went from 94 correct / 10 missed to **97 correct / 8 missed**, with
no new wrong matches, and the MusicBrainz corpus did not move at all.

It was reverted anyway. The premise is false, and the existing tests say so — a deluxe edition
carries "Yesterday" *and* "Yesterday - Live at the BBC". Enabling it broke the karaoke, cover,
instrumental and live-vs-studio cases, which are the product's central promise. Three corpus rows
do not outrank them.

Two things worth keeping from the attempt:

  * **`Matching.match/3`'s `veto_respected` postcondition caught it**, before any test did. Adding
    the exception to `Strategy.Text` alone fired the assertion, which is precisely the
    cross-check it was written to be.
  * **These misses are not fixable from the metadata.** Knowing that *At Folsom Prison* is a live
    album is a fact about the world, not a property of the strings. That is the strongest
    argument in this file for an external catalogue — see below.

### An ensemble is often named by wrapping its leader

From a real transfer: *The Jimi Hendrix Experience* failed to match *Jimi Hendrix* — same track,
same album, *Electric Ladyland*.

Neither existing rule saw it. The backing-band rule looks for "X and *the* Ys" and there is no
conjunction. Every name-level comparison fails because each side is a **single different
string**: `{the jimi hendrix experience}` against `{jimi hendrix}` shares no member, is no
subset, and is not partially overlapping. The credits read `:unrelated` and the text rung refused
before scoring.

The relationship is visible one level down. The *words* of one credit are inside the other's, and
that is how a great deal of music is credited:

| | |
| --- | --- |
| The Jimi Hendrix Experience | Jimi Hendrix |
| The Dave Brubeck Quartet | Dave Brubeck |
| Miles Davis Quintet | Miles Davis |
| Duke Ellington Orchestra | Duke Ellington |

A word-level subset now reaches `:contained` — ambiguous, not agreed. That distinction is what
makes it safe: `:contained` has to be corroborated by an album, a duration or a barcode.
*Neil Young & Pearl Jam* against *Neil Young* is a word subset too, and still declines when
nothing supports it.

**Two words at least.** One shared word is a coincidence — "Bush" inside "Kate Bush" — and every
one-word artist is already handled by the name-level checks. That floor is pinned by a test,
because a mutation to one initially passed unnoticed.

Measured: both corpora unmoved. Credit corpus 96 correct / 12 equivalent / 7 missed / 0 wrong,
declines 5 of 5; MusicBrainz corpus 82 / 12 / 5 / 1. The rule adds a case and costs nothing.

### An artist-alias table would buy about three cases in a hundred

Measured before building one, because the obvious answer to "Ye is Kanye West" is a MusicBrainz
alias dump, and it is a multi-gigabyte dependency.

Over the 115 judged credit cases, the source's credit and the *correct* candidate's credit
relate as:

| | |
| --- | --- |
| `:same` | **101** |
| `:contained` | 7 |
| `:unrelated` | 7 |

Only the seven `:unrelated` pairs are ones an alias table could touch, and three of those are
SpongeBob voice actors against SpongeBob characters, which no catalogue reconciles. The rest are
genuine renamings — *Young Jeezy* to *Jeezy*, *Dramacydal* to *Outlawz* — and one catalogue
spelling *Cappadonna* as *Capadonna*.

Diacritics are **not** among them: `Normalize.text/1` already folds `JAŸ-Z` to `jay z`, and
`Beyoncé`, `Sigur Rós` and `Motörhead` all normalize with their unaccented spellings.

**Most of that value is available without the dump.** Those pairs share a name and disagree about
another, and the classifier was reading "not a subset" as `:unrelated` — refusing outright what is
merely ambiguous. Treating partial overlap as `:contained` puts them on the same evidentiary
footing as any other ambiguous credit: allowed to match if something independent confirms it.

Measured: **+2 correct, −3 missed, no new wrong matches**, and the MusicBrainz corpus did not
move. Disjoint credits stay `:unrelated`, which the "a different artist with the same title does
not match" test holds in place.

An alias table is therefore worth perhaps one or two more cases in a hundred here, against a
build step and a shipped dataset. Revisit it when a corpus shows it earning more — a library
heavier in non-Latin scripts or in artists who have renamed would be the case that changes the
arithmetic.

### MusicBrainz: the useful question is ISRC equivalence, not artist aliases

Investigated because "use MusicBrainz" kept coming up, and the first two framings of it were
both wrong.

**Not an alias table.** Measured above: worth one or two cases in a hundred, most of which came
free from reading partial credit overlap as ambiguous.

**Not a live lookup per track.** 1 request/second means a 5,000-track playlist would spend 90
minutes on MusicBrainz alone.

**The thing it is actually good for is the reissue problem.** An ISRC names a recording *as
issued*, so the same master carries a different code on every reissue — this is what
`Tidal.by_isrc/4` had to be fixed for. MusicBrainz groups them:

    /ws/2/isrc/USJY50700001?fmt=json&inc=isrcs
    → recording ea8c7b4c…  "Setting Forth"  isrcs: [USJY50700001, USJY51700100]

Roon's 2007 code and TIDAL's 2017 code, one call, one recording. That is the exact bug that
reported *Setting Forth* as "nothing found on the destination".

#### What it would buy, measured

Against the credit corpus, resolving a missed ISRC through its MusicBrainz family:

| | |
| --- | --- |
| Currently-missed cases rescued | **5 of 7** |
| Agreed with the human label | 6 |
| **Contradicted a human label** | **0** |
| Ambiguous (several candidates in one family) | 1 |
| Family known, no offered candidate in it | 2 |

Five of the seven remaining misses is the entire live-recording backlog — Johnny Cash's
"Jackson", both James Browns, the Kanye freestyle. And they return as **identifier** matches,
which sidesteps the version veto rather than fighting it. That is the same class of problem the
rejected same-release exception tried and failed to solve by string comparison.

#### What it would cost

  * **One call per tricky track**, and only where the identifier rung already missed — 14 of 97
    ISRC-bearing corpus cases, about one in seven.
  * **1 request/second**, reported as 1200 per window in `X-RateLimit-Limit`.
  * **Cacheable forever.** An ISRC-to-recording mapping is a stable fact, so this belongs in the
    two-tier cache beside `catalogue_release_lookups`, with the same `pg_cron` pruning. A row is
    an ISRC, a recording id and a small array — call it 100 bytes. A million of them is 100 MB,
    which Supabase holds without noticing.
  * **The full dump is a different proposition entirely**: 4–5 GB compressed, tens of GB
    expanded. That does not belong in Supabase and is not needed for any of this.

#### The concerns worth naming before building it

  1. **An identifier match skips the veto.** That is correct for a real ISRC and a risk for a
     borrowed one: MusicBrainz is user-edited, and a wrongly grouped family would produce a
     confident wrong match, which is the one outcome this project is organised against. A
     MusicBrainz-mediated match should keep the duration check and carry its own strategy name,
     so the report can say where the certainty came from.
  2. **Ambiguity is real but rare** — one case in nine had three candidates in one family, and
     needs a tie-break rather than a coin toss.
  3. **A third party in the transfer path**, mitigated by where it sits: a fallback after the
     identifier rung has already missed, so an outage degrades to today's behaviour rather than
     failing a transfer.
  4. **Citizenship.** A contactful `User-Agent` is required and the rate limit is real. This is
     a natural `ExternalService` module — its own breaker, its own 1/sec limiter, `Retry-After`
     honoured.
  5. **Licensing needs checking before shipping**, not assuming. The core data is understood to
     be public domain, but that should be confirmed against MetaBrainz's current terms rather
     than taken from memory.

#### A finding that came free

Five corpus tracks carry **two ISRCs in one tag**, semicolon-separated, because Picard wrote the
equivalence into the file. `Music.Isrc.normalize/1` rejects a 25-character value, so a future
tag-based import would drop the identifier entirely rather than gaining two. The CSV path is
unaffected — Roon writes one — but a library importer would need to split on the separator.

### Query construction is not the recall problem

Worth recording as a *negative* result, because it is the obvious next move and it does not work.

Text search queries `title + every credited name`, which for
*"2Pac feat. Danny Boy, Big Syke & CPO-Boss Hog"* is a long and polluted string. The obvious fix
is to query the primary credit only, which `Normalize.credits/1` now makes easy.

Measured over the 97 corpus cases carrying an ISRC: **81 recalled with the whole credit, 81 with
the primary only, and not one case rescued by the change.** The 16 that neither query finds are
catalogue limits rather than query construction. Do not spend time here without new evidence.

### Classical music: what a work rung fixed, and what it did not

Found by building a playlist designed to fail (`dev/experiments/build_hard_playlist.py`) and
transferring it. **0 of 8** classical tracks matched, and the diagnosis is three separate
failures stacked on one track:

    source     Antonio Vivaldi - The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro
    offered    Joshua Bell    - ...Op. 8 No. 4, RV 297 "Winter": I. Allegro non molto   0.494
               Nigel Kennedy  - ...Op. 8 No. 1, RV 269 "Spring": I. Allegro             0.425
               Janine Jansen  - Vivaldi: The Four Seasons: Spring...RV 269, Op. 8 No. 1 0.321

  1. **The credit names different people.** A classical source credits the *composer*; a
     catalogue credits the *performer*. "Antonio Vivaldi" against "Nigel Kennedy" shares no
     name, so `credit_match/4` answers `:unrelated` and the text rung refuses outright. The
     credit model assumes both sides name the same act, and here they never do.
  2. **The identifying information is inside the title**, as prose, in an order each catalogue
     chooses for itself. `Op. 8 No. 1`, `RV 269` and `I. Allegro` are *identifiers* - as
     decisive as an ISRC - and they are being compared as words.
  3. **Generic similarity ranks the wrong piece first.** Winter scored above Spring for a Spring
     query, because the strings happen to overlap more. Lowering the threshold would match the
     wrong concerto, not the right one.

None of this is fixable by tuning. It wants catalogue-number extraction (`Op.`, `RV`, `BWV`,
`K.`, `D.`) treated as an identifier rung, and a credit model that knows composer and performer
are different roles. That is a feature rather than a rule change, and it is the largest single
gap this project has found in its own matching.

#### What was built

`OnePlaylist.Music.Work` reads a **work signature** out of a title — catalogue number, named
form and number, key, movement — and `Strategy.Work` matches on it, above the text rungs and
below the identifier ones.

Two decisions carry it:

  * **The composer stands in for the credit.** Rather than requiring `artists` to agree, which
    is guaranteed to fail here, the rung asks whether the source's credit appears *anywhere* in
    the candidate. "Vivaldi: The Four Seasons" is how a catalogue names the composer.
  * **A generic form cannot identify a work.** Vivaldi wrote a *Concerto for Two Cellos No. 2 in
    G minor* and a violin concerto also numbered 2 in G minor, both credited to Vivaldi. Form
    plus number plus key agrees for both, and the rung matched them to each other until
    `concerto`, `sonata`, `suite`, `prelude`, `fugue` and `aria` were excluded from that path.
    `Concerto grosso No. 2` and `Brandenburg Concerto No. 2` each name one piece and are fine.

Measured on 57 classical sources with real TIDAL candidates: **24 matched by the work rung and
13 by text, against 0 of 8 before.** 15 remain below threshold and 5 were offered nothing at all.

#### What it does not fix

  * **Sources with no work signature.** Roughly a third of the corpus: a title naming a piece
    without a catalogue number, and with a form too generic to substitute.
  * **MusicBrainz's ISRC lookup cannot help here.** Only **16 of 294** classical tracks in a real
    library carry an ISRC, so the equivalence lookup built for reissues has nothing to work with.

#### The works lookup, built and measured

Its *works* endpoint is a different matter. It answers "Brandenburg Concerto no. 2 bach" with
*Brandenburgisches Konzert Nr. 2 F-Dur, **BWV 1047***, putting the number in a title where
`Music.Work.parse/1` already reads it. It also crosses numbering systems, which nothing local
can: Scarlatti's *Sonata in D minor, **L 413*** comes back as ***K 9***.

The trigger is deliberately narrow, because MusicBrainz allows one request a second. All three
must hold: the match has already failed, the source's own title yields no catalogue number, and
**some candidate has one**. The last is what keeps a pop playlist out — a search for "Woo"
answers with 48,000 works — and costs nothing, being a property of results already in hand.

Measured on the 57-case classical corpus: **2 more matched**, and one of them is the *Concerto
for Two Cellos* that the local rung had matched to a **violin** concerto. RV 531 turns a false
positive into a correct match, which is worth more than the count suggests.

Two things the measurement corrected:

  * **Query by surname, not by the full name.** "Brandenburg Concerto no. 2 johann sebastian
    bach" returns *Johann Sebastian Bach auf Rügen* and no catalogue number; "…bach" returns the
    concerto. Forenames match works *about* a composer.
  * **A prototype counting catalogue overlap over-reported by more than double.** It said five
    rescues; the real path, which applies the movement, composer and corroboration gates, gives
    two. Two of the five never needed rescuing — the local rung already had them.

#### The corpus is about half contaminated, and the numbers should be read that way

`harvest_classical.py` matches on words — `symphony`, `prelude`, `mass`, `nocturne`, `requiem` —
and those words appear in pop titles. Justin Timberlake's *Summer Love/Set the Mood (prelude)*,
The Verve's *Bitter Sweet Symphony*, Gang Starr's *Mass Appeal* and Rihanna's *Woo* are all in
the classical corpus. Of 27 cases with candidates but no catalogue number, roughly 13 are
genuinely classical.

So "2 of 57" understates the rate on real classical material, and every number in this section
should be read as a floor. Tightening the filter — requiring a catalogue number, a movement
marker, or a composer-shaped credit — is worth doing before the next round of work here.

### What a deliberately adversarial playlist actually breaks

116 tracks from a real library, eight per category, each category a failure mode this project
has hit or has never tested. `dev/experiments/hard_playlist.csv`, built to be transferred.

| Category | Result |
| --- | --- |
| `non_ascii_artist` | 8/8 by identifier |
| `multi_isrc` | 8/8 - but every one by **text**, because a two-ISRC tag is 25 characters and `Isrc.normalize/1` rejects it |
| `medley` | 8/8 |
| `no_isrc` | 7/8 |
| `live_album_plain_title` | 8/8 |
| `guest_credit` | 8/8 |
| `version_in_title` | 6/8 |
| `shared_title` | 22/28 |
| `co_billed` | 5/8 |
| `long_credit` | 5/8 |
| `non_ascii_title` | 5/8 |
| **`classical`** | **0/8** |

**90 of 116 matched, and not one match landed on an artist the source did not name.** That is
the property worth checking under adversarial input, and it held: of 90 matches, zero had
credits sharing no name with the source - on a playlist containing 28 tracks whose titles
several different artists recorded.

Two smaller findings:

  * A semicolon-separated ISRC survives CSV quoting, reaches the parser, and is then discarded
    by `Isrc.normalize/1` as malformed. Text recovers all eight, so nothing is lost today - but
    the identifier was there and was thrown away, and splitting on the separator would move
    eight tracks from a guess to a certainty.
  * The harvester's `classical` selection is eight Vivaldi tracks from one album, because it
    sorts by artist and takes the first eight. Enough to expose the category and too narrow to
    size it; diversifying by artist is worth doing before drawing conclusions about classical
    beyond "it does not work".

### What has actually been measured about match quality

Match quality is the product, so it is worth being precise about which numbers mean what.

#### The honest cross-service number

Measured 2026-08-23. **100 recordings catalogued by MusicBrainz, matched against the live TIDAL
catalogue, with the ISRC withheld from the engine.** Two organisations catalogued these
recordings independently, over twenty years, with no shared source — which is what every
earlier measurement here lacked.

| | At measurement | After the duration fix |
| --- | --- | --- |
| Certainly right — TIDAL's ISRC is one MusicBrainz records for that recording | **82%** | **82%** |
| Probably right — identifier differs, duration agrees within 3s | **94%** cumulative | **94%** cumulative |
| Possibly wrong — duration disagrees materially | 4% | **1%** |
| Found nothing | 2% | 5% |

So the honest claim is a **band, 82%–94%**, on the *hard* path: identifiers withheld, text and
fuzzy carrying the whole match. It is not comparable to Soundiiz's and TuneMyMusic's advertised
97–99%, which are whole-catalogue figures dominated by ISRC hits — and this project's own
ISRC path measured 60/60 and 30/30 in earlier runs.

The second column is the same corpus re-scored after the change described under *the genuine
errors* below. Three confidently wrong answers became honest misses and **no correct match was
lost** — which is the trade this engine is supposed to make, and the reason the top two rows do
not move.

**Reproduce with** `dev/measure/fetch_musicbrainz.exs` then `bin/remote dev/measure/match_rate.exs`
for a live run, or `bin/remote dev/measure/replay.exs` to re-score the captured candidates
against the engine as it stands — no API calls, and the only way to tell whether an engine change
helped or merely moved the failures around. The corpus and the per-track results are committed.

#### Why it is a band and not a number

The obvious oracle — does the chosen TIDAL track's ISRC match the source's? — proves a match
right and **cannot prove one wrong**. An ISRC identifies a *release's* track, not a performance,
so one recording carries many: Fleetwood Mac's "Dreams" has seven. When two services reference
different releases of one performance, the identifiers differ and the match is correct anyway.

The first run scored 16 wrong, and reading them showed most were not. Six were Björk's
*Homogenic*, matched title-for-title at 0.980 — a perfect text score — to a TIDAL entry whose
ISRC MusicBrainz does not list. Duration agreement is what separates "different release" from
"different recording", and adding it moved 12 of the 16 into *probably right*.

#### Where the remaining failures actually are

Not spread evenly, and not mostly the engine's fault.

**TIDAL's text search is the binding constraint.** It returned an ISRC-matching candidate for
only **86%** of the corpus. Where the right recording *was* among the candidates, the engine
picked it 95% of the time. Improving the ladder cannot fix the other 14%; only a better query
or a second lookup can.

**The genuine errors clustered on unlabelled versions — and this has since been fixed.** Three of
the four contradicted matches were Kraftwerk: `Die Roboter` at 373s matched to a 463s recording,
`Neonlicht` at 535s to 344s. Both catalogues carry several versions of each and **neither labels
them**, so the discriminating-tag veto had nothing to fire on and the text rung saw two identical
titles by one artist.

The first instinct was that duration should *discriminate* between such candidates rather than
merely contribute a signal. Scoring the real candidate lists showed that was the wrong diagnosis:
in every one of the three cases the correct recording was **not among the candidates at all**, so
there was nothing for a tie-break to choose. The problem was not ranking, it was that a match had
to be returned.

The actual cause is structural. `Similarity.duration_proximity/2` already distinguished *missing*
(`nil`) from *far apart* (`0.0`), and the weighted mean was throwing that distinction away — a
saturated `0.0` is just one low term among four. Worse, the text rung's band is `0.80`–`0.98`,
entirely **above** the default `:medium` threshold of `0.75`, so *every* match that rung returns
is confident by construction. A rung that cannot express doubt has to decline instead.

So `Signals` now carries a `duration_conflict` flag, and it stops the text rung specifically. It
is deliberately **not** part of `Signals.vetoed?/1`: vetoing everywhere would discard the
candidate, and the fuzzy rung — whose band is `0.0`–`0.79` — can score it low instead, which is
strictly more informative. The rung that cannot express degrees declines; the rung that can scores
it. Both surviving behaviours are pinned by tests, including the reissue case that must *not*
be rejected.

Result on this corpus: wrong matches 4 → 1, with `certain` and `probably right` unchanged. The
single survivor, `Blue in Green` at 328s against 324s, looks like an oracle artefact rather than
an engine error — the chosen track is the same performance on a licensed compilation, which
carries its own ISRC and a 4-second-different master, so it falls outside both the ISRC set and
the 3-second window. Neither test the oracle has can resolve it.

**One recall failure worth understanding.** `Freddie Freeloader` returned no match although an
ISRC-matching candidate was among the twenty offered — the ladder rejected the right answer.

#### The earlier numbers, and why they are floors rather than rates

Every measurement before the one above is soft in the same way: both sides came from the same
metadata.

| Measurement | Result | What it proves | What it does not |
| --- | --- | --- | --- |
| TIDAL → TIDAL, ISRCs present | 60/60 `:exact_isrc` | The ISRC rung and the tie-breaking work against a real catalogue | Nothing about text matching |
| TIDAL → TIDAL, ISRCs stripped | 98% via text | Normalization survives a real catalogue's spellings | Not a cross-service rate: source and candidates are both TIDAL, written by one cataloguer |
| TIDAL → Navidrome, ISRCs present | 30/30 `:exact_isrc` | The whole cross-provider pipeline: two adapters, two shapes, one ladder | Nothing about text |
| TIDAL → Navidrome, ISRCs stripped | 30/30 via text, at **0.929** | Text carries a cross-provider match when rung 1 cannot | The local library's tags were *generated from* the TIDAL corpus |

Treat all four as regression floors for the code. The MusicBrainz measurement is the one to
quote about the product.

#### What this measurement still does not cover

  * **100 tracks, 9 albums.** Enough to locate the failure modes, not to put a confidence
    interval on 82%.
  * **Well-known releases only**, deliberately: an obscure record missing from TIDAL would
    measure catalogue coverage and be scored as a matching failure. Real libraries contain
    obscure records, so the true rate on a real library is lower.
  * **One destination.** TIDAL's search behaviour is baked into the 86% recall figure; another
    service would move it in either direction.
  * **No non-Latin scripts.** The corpus reaches diacritics, a middle dot and an inverted
    question mark, but nothing in Cyrillic, Japanese or Arabic.

### Deezer — effectively closed

- The public API has been disabled for new registrations: **new tokens cannot be obtained**,
  though existing tokens still work. The JavaScript and native SDKs are deprecated/unmaintained.
- Treat as read-only-at-best and not a launch platform.

### Amazon Music — closed beta

- Web API is in closed beta; access requires contacting an Amazon Business Development rep.
- Explicitly designed to support playlist transfer between services, so it is the right target
  *if* access can be obtained.

### Self-hosted / open platforms — the strategic opening

Plex, Jellyfin, Emby, Navidrome, Subsonic/OpenSubsonic all have open, documented, unlimited
APIs and no gatekeeping. Combined with file import/export (M3U, XSPF, CSV, iTunes XML) and
MusicBrainz for identity, these are the platforms where a new entrant can ship a genuinely
better product *today* with no quota negotiation.

#### The cost of that opening: the server address is user input

Every hosted provider's base URL is a constant we compile in. A self-hosted one is whatever
the user pastes into `/connections`, and this application then makes an outbound request to
it. That is **server-side request forgery by design** — it is not a bug to be closed, because
the addresses that matter are exactly the ones a naive SSRF filter blocks: `localhost`,
`192.168.x.x`, `10.x.x.x`, a `.local` name on a home network.

What is actually in place (`OnePlaylist.Providers.SubsonicCredentials`):

- the scheme is restricted to `http`/`https`, which closes off `file:`, `gopher:` and friends;
- the request is initiated by an authenticated user, naming their own server, explicitly;
- it carries no ambient credentials — only the salted token derived from what they typed;
- nothing of the response reaches the user except a parsed Subsonic envelope, so probing an
  internal address learns only "not a Subsonic server", never a body or a header.

That last property is what keeps this acceptable, and it is worth *not* accidentally weakening
by surfacing raw upstream errors. It is sized for "Jason and a handful of people", not for a
public multi-tenant deployment. **Before this is hosted for strangers**, the fix is to move the
outbound call out of the web tier — a per-user egress proxy, or an allowlist the user opts into
per server — rather than to try to enumerate bad addresses.

### Cross-cutting

- **OAuth token lifecycle is the operational core**: store refresh tokens encrypted, refresh
  proactively before expiry, handle revocation, and never log them.
- Every platform needs its own `external_service` module with its own breaker, rate limit,
  concurrency limit, and retry policy — the numbers differ by an order of magnitude between
  Spotify and YouTube.
- Honour `Retry-After` explicitly. `external_service`'s exponential backoff is the right
  default, but a `429` carrying an explicit delay should drive the wait directly.
- Terms of service: most platforms forbid using their API to facilitate migration *away* from
  them, or to build a competing service. Read them before publishing.

---

## 4. Product shape implied by all of the above

A defensible `one_playlist` v1:

1. **Match quality as the headline feature** — ISRC-first, a visible confidence score, a
   complete report of what didn't transfer and why, and a manual resolution UI. This is where
   every incumbent is weakest.
2. **Start with the platforms that will actually let you in**: Tidal, self-hosted
   (Plex/Jellyfin/Navidrome/Subsonic), and file import/export. Spotify and Apple Music as
   allowlisted/personal-tier integrations from day one, with a documented path to broader
   access.
3. **Sync as the subscription hook**, built on Oban Cron + `external_service`, with per-pair
   sync slots mirroring the incumbents' pricing shape.
4. **Transparency and correctness as the brand.** Every transfer produces a durable,
   inspectable, shareable report.

---

## 5. Beyond transfer: One Playlist as a place playlists live

Everything above treats this application as a **pipe**: playlists live at services, and the
product moves them between. The direction below makes it a **place** as well — playlists live
here too, fully editable, and the app is a legitimate source and destination for its own
transfers and syncs.

That reads like a change of subject and is not one. It follows from §2. The whole difficulty of
transfer is that a recording has a different identity at every service; the answer this project
has been building — ISRC, then UPC and position, then work, then text, with MusicBrainz as the
tie-breaker — produces a *correspondence* between services that is thrown away the moment a
transfer finishes. A library is where that correspondence gets to live.

### The feature set

| | Feature | What it means | Rests on |
| --- | --- | --- | --- |
| **L1** | The library | Playlists stored by this application, owned by a user | new schema |
| **L2** | Editing | Create, rename, delete, reorder, add and remove tracks | L1 |
| **L3** | The library as a transfer endpoint | Source *and* destination for transfer and sync | L1, `Runner` |
| **L4** | Enrichment | Every library track resolved to as much metadata as can be obtained | `MusicBrainz`, `Catalogue`, `Matching` |
| **L5** | The identity spine | A library track carries its id at every service it is known at | L4, `Matching` | *(built)* |
| **L6** | Files in and out | Import a file into the library; export a library playlist to any format | `Formats`, `Imports`, `Exports` |
| **L7** | My Playlists | One page listing everything, grouped by where it is stored | L1, `Providers` |

L1–L3 are the product. L4 and L5 are what make it worth more than a folder of CSVs. L6 and L7
are largely re-pointing machinery that already exists.

### The library is the identity spine, and that is the point

§2 ends with a note to *cache resolutions* — `(source_service, source_id) → (dest_service,
dest_id, confidence)` — and calls it "the asset that compounds". The library is that cache with
a face on it.

A library track is not a copy of a TIDAL track. It is **a recording**, carrying every identifier
it is known by: ISRC and its MusicBrainz family, a MusicBrainz recording id, a release barcode
and position, and the provider id at each service where it has been located. Once a track is in
that state, moving it somewhere is a **lookup rather than a match**.

That is the strategic claim worth testing, because it inverts the product's economics:

| | Cost of transferring one track |
| --- | --- |
| Today | one search per track per transfer, matched every time, with the failure rate §2 measures |
| With a spine | one search per track *ever*, then an id lookup |

It also compounds in the direction the matching work already points. A track the ladder resolved
confidently once never has to be resolved again; a track a person corrected by hand
(`transfer_overrides`) has been corrected **for every future transfer of that recording**, not
just for the report row that prompted it. That is a materially better answer to §1's
"match quality is the product" than more scoring.

### L5, once built

`recording_identities`, one row per recording per service, hung off `library_recordings` —
so a transfer between two services *neither of which is the library* still teaches it both
ids, and a later transfer out of the library gets them for free. A pairwise cache would have
been simpler and wrong twice: it grows with the square of the number of services, and it has
nowhere to put the ISRC enrichment found or the correction a user made.

Three decisions, each of which could have gone the other way:

**Anchored on a canonical ISRC, or not recorded at all.** `find_or_create/1` joins only on an
ISRC, never on a title, because merging two recordings that turn out to be one is reversible
and splitting one that was never two is not. So a Subsonic library with no ISRCs teaches the
spine nothing rather than filling the shared store with duplicates. That makes the duplicate
risk structurally impossible rather than merely unlikely.

**Only evidence at `:exact_upc` or better gets in** — the identifier rungs, a person's own
choice, and a verbatim store. Deliberately stricter than the threshold the same transfer
matches at, and the asymmetry is the whole point: a `:high` text match is good enough to put a
track in a playlist, where a person sees the result and a wrong answer is one row in one
report. It is not good enough to assert as a fact about the world's music, for ever,
unreviewed. The rule is a `Bond` precondition on `Identities.record/4` rather than a
convention each call site remembers.

**The row carries a snapshot of the destination's track.** No adapter has a *fetch one track
by id* callback, so without `title`, `album` and `artwork_url` a recalled identity could name a
track but not describe it — and a transfer report has to show what it matched to. With them,
recall costs **no request at all**, which is the economic claim above made real. The price is
a snapshot that can go stale, and it is bounded: `confirm_written/5` reads the destination
playlist after every run, so an id that has stopped working surfaces as a track reported
written and not found. Nothing crawls the services on a schedule to re-check; that would be a
lot of requests for a question that answers itself in use.

`recall/3` still refuses to answer with the source track itself, because a same-service
transfer is handled before the spine is consulted at all — see below.

### A transfer within one service needs no matching

Obvious once stated and worth stating: if a track came from the catalogue it is going to, its
own id is already the answer. A TIDAL→TIDAL copy was issuing one search per track to rediscover
ids it was holding.

The condition is a **capability**, `:global_ids`, and not a comparison of provider names. That
distinction is the entire content of the feature: two Subsonic connections are two *different
servers*. Both say `:subsonic`, and an id from one names nothing on the other — or, far worse,
names something else. Any rule phrased as "source provider equals destination provider" is
wrong for every self-hosted provider this application will ever add, and would put arbitrary
tracks into a user's playlist without a single failure to notice.

TIDAL declares it, because its ids name entries in one catalogue every account shares. The
library declares it, being a single store. Subsonic does not.

#### It cost a test fixture, and that was the real work

`transfers_test.exs` transferred `:tidal → :tidal` as a generic stand-in for "a transfer", so
the shortcut short-circuited **every test in the file** — search, matching, candidates and
overrides all stopped being exercised while the suite stayed green on the ones that remained.
A feature that silently deletes coverage is worse than the feature is worth.

The fixture now sources from the **library**, which needs no HTTP stub and is a genuine
cross-service transfer, with two tests added for the same-service path itself. The general
lesson is about fixtures rather than about this feature: a fixture that uses the simplest
configuration is fine until the simplest configuration becomes a special case, and nothing
warns you when it does.

### Matching inverts when the destination is the library

The most important design consequence, and the easiest to get wrong.

Everywhere else in this application a failure to match is a **failure**: the destination
catalogue does not have the recording, the track cannot be transferred, and the report says so.
That anxiety is what `TrackNotMatched`, the confidence threshold and the version veto all exist
to serve.

The library has no catalogue. It can hold any recording, so a track arriving at it can always be
stored. Matching still runs — against the user's own recordings, to decide whether this is
something they already have — but a miss means **create a new recording**, not "unmatched".

So the failure mode flips. Transferring *out* of the library risks a wrong match; transferring
*into* it risks a **duplicate** — the same recording stored twice because the second arrival was
not recognised. Duplicates are the library's version of the silent wrong answer, and the same
rule applies: never merge two recordings on weak evidence, and make the join inspectable and
reversible. Merging is destructive in a way adding is not.

`Formats` already documents this asymmetry for files, where export "cannot fail to match". The
library is the same shape with dedup added.

### Is the library a provider?

The open question, and the one that decides how much code this costs.

`OnePlaylist.Transfers.Runner` is written entirely against `adapter.*`. If the library
implements `OnePlaylist.Providers.Adapter`, transfer and sync work with **no pipeline changes**
at all — `create_playlist/3`, `add_tracks/4`, `remove_tracks/4`, `playlist_track_ids/3` and
`stream_tracks/3` become database operations and nothing above notices. That is a large prize.

What resists it is `OnePlaylist.Providers.Connection`. Every callback takes one; `provider/0`
carries a postcondition that the answer is in `Connection.providers()`; and `usable?/1` requires
a non-blank `access_token`. A library needs no credential at all.

**Recommendation, not a decision:** implement the behaviour, and let `Connection` become what it
has been drifting toward — *a user's authorization to act at a place*, rather than *an OAuth
grant*. Navidrome already moved it halfway: no expiry, nothing to refresh, a password where a
token was assumed. A `:library` connection moves it the rest of the way, with `usable?/1`
gaining an honest clause saying a library connection needs no credential to be usable.

Worth saying plainly that this would be the **second** stretch of that type. A third should
prompt splitting it rather than widening it again.

The alternative — a third kind of endpoint beside "provider" and "file" — keeps `Connection`
clean and puts a branch in every stage of the runner. `:file` is precedent for exactly one such
branch, in `read_source/1`, and it is tolerable because a file is source-only. The library is
both, so the branching would not stay contained.

### The recording store is global; the playlists are per user

Two tables doing different jobs, and conflating them is the mistake to avoid.

  * **Recordings** are facts about the world — this ISRC, this MusicBrainz id, this id at TIDAL.
    They belong to nobody, are worth sharing between users, and are the thing that compounds.
    `catalogue_release_lookups` and `musicbrainz_isrc_lookups` are already this shape, so the
    RLS pattern for an ownerless table exists and is documented in the migration that created
    the first one.
  * **Playlists and their contents** are the user's, protected by the usual `auth.uid()` policy
    shape.

Nothing about who owns what leaks from a shared recording store: membership lives in the
per-user table.

> #### Reordering: dense integers, and a drag that does not trust the client

Two chevrons per row became untenable the moment enrichment needed a chevron of its own
to expand a row — three in one row, two of which reorder, is worse than either feature
deserves. It is now a drag handle.

The part worth recording is where the ordering is computed. The obvious shape is for the
client to reorder the DOM and post the new sequence; the server then writes whatever it is
sent. That trusts the client to have got it right, and a stale or malformed sequence
silently rewrites somebody's playlist. So the hook reports only **what was dropped where** —
an entry and a neighbour — and `Library.place_entry/5` derives the order. An id that is not
in the playlist is simply not found, and nothing moves.

It also does not manage the list's DOM, which `AGENTS.md` would require `phx-update="ignore"`
for; that would stop the list re-rendering at all, including removals and enrichment landing
while the page is open.

The handle is a `<button>` so the arrow keys still reorder, through the same `move_entry/4`
the chevrons used. The known gap is touch: HTML5 drag does not fire there.

### Rejected: fractional ranks for ordering {: .info}
>
> This section first said ordering wanted fractional or lexicographic ranks rather than dense
> integers, "because reordering a 5,000-track playlist by hand should not be a 5,000-row
> update". That was argued rather than measured, and it does not survive being measured:
> renumbering half a five-thousand-row playlist in one statement is **2.3 ms**. Adjacent moves
> — the only reorder L2 offers — do not even need that, being a swap of two `position` values.
>
> So dense integers stayed, and the precision cliff, the rebalancing pass and the opaque sort
> key that come with fractional ranks were all avoided. Worth revisiting only if a drag-and-drop
> reorder that moves an item many places at once turns out to be slow, which is a measurement
> nobody has yet needed to make.

### Enrichment is a budget, not a step

MusicBrainz asks for one request a second and means it (§3). A 5,000-track library needing one
lookup each is **83 minutes**; needing a recording lookup and a work lookup each is closer to
three hours. So enrichment cannot be something that happens on import while somebody waits.

What that implies:

  * **Background and resumable.** Oban, one job per track or per batch, safe to re-run.
  * **Incremental, and visible as such.** A track enters the library with whatever its source
    carried and improves over time. The UI has to be honest about a partly-enriched track rather
    than hiding it until it is complete.
  * **Cheapest source first.** Much of what enrichment wants is already free: a track arriving
    from TIDAL brings an ISRC, a barcode, artwork and a duration. MusicBrainz is for what no
    single service knows — the ISRC family, the work, the cross-service identity — which is
    exactly the ordering `OnePlaylist.MusicBrainz` already follows in only being consulted after
    a lookup has missed.
  * **Prioritised by attention.** A playlist the user is looking at is worth enriching before
    one they imported and closed.

### What L4 turned out to be, once built

`OnePlaylist.Library.Enrichment`, run by an Oban worker on a queue of **one** — sized to
MusicBrainz's one request a second rather than fighting it — enqueued as each new recording
arrives and swept nightly by `EnrichmentSweeper` for backfill and re-asking.

Three decisions came out of building it, and two were forced by measurement rather than chosen.

**MusicBrainz's search score is not a verdict.** `dev/probes/musicbrainz_enrichment_shapes.exs`
asked for *Corduroy* by *Pearl Jam* and got a **live Barcelona bootleg at score 100**. Taking the
top hit would have attached that recording's identity, and then its ISRC, its length and its
artwork, to the studio track somebody imported — enrichment making the data *worse*, which is the
failure mode this feature has to be designed against and the one it would be hardest to notice
afterwards.

The fix cost nothing, because the answer already existed: candidates are scored through
`OnePlaylist.Matching` at `:high`, exactly as candidates from any service are. The version veto,
the duration conflict and the credit rules all apply because they are the ladder's. And a
recording with nothing to corroborate with declines on its own — `Strategy.Text` scores an
uncorroborated match at `0.89`, `:high` is `0.90` — which is the ladder already knowing that a
title and an artist are not enough. No threshold of enrichment's own was invented.

**Filling gaps is not correcting.** Nothing is ever overwritten. What the source said is what the
user's playlist shows, and a background job quietly replacing a title with MusicBrainz's
canonical spelling is a surprise nobody asked for; telling a disagreement from an improvement
needs a provenance model, which is a bigger feature. This is stated as a `Bond` postcondition
rather than a convention, because no input can falsify it — only a future edit can, silently, on
a schedule, for every recording in the library. Verified by mutation.

**One request answers everything.** `inc=artist-credits+releases+isrcs+work-rels` returns the
ISRCs, the length, the credit, the releases with their barcodes, and the work relations. So the
cost is one request per recording, or two when there is no ISRC and it has to be searched for
first. Artwork is the exception and is *not* in that response: only a release lookup carries
`cover-art-archive`, so it is one request per **release**, cached — an album's worth of
recordings would otherwise ask the same question twelve times. The URL itself is constructed
rather than fetched, which is why asking first matters: storing one unchecked puts a broken image
in every view that shows the track.

Measured live. A first probe of six recordings identified all six, three by ISRC and three by
search. The full dev library then backfilled through the nightly sweep's own path — 141 jobs on
the queue of one, drained in about twelve minutes:

| | |
| --- | --- |
| Enriched | 150 of 150 |
| Identified at MusicBrainz | 140 |
| Carrying an ISRC | 135 → 137 |
| Carrying a length | 79 → 135 |
| Carrying a barcode | → 100 |
| Carrying cover art | 8 → 104 |
| Values overwritten | 0 |

The ten misses are worth naming, because they are **MusicBrainz coverage rather than matching**:
nine carried an ISRC MusicBrainz does not index — two Dead Man Walking soundtrack collaborations,
three tracks from a 2022 album, an extended version, a live cut — and one, a non-album medley,
had no ISRC and was correctly declined rather than guessed at. Nothing was matched to the wrong
recording, which is the number that actually matters here.

### A recording has many releases, and they disagree

Found by looking at the screen rather than the tests. Eight tracks of *Dark Matter*
resolved to **three** different MusicBrainz releases, so the album contradicted itself:
two barcodes, and a cover on two tracks out of eight. Thirteen of the library's albums were
affected.

The cause was one line — `List.first(releases)` — and it is worth naming why that was
wrong rather than merely unlucky. MusicBrainz lists every release a recording appears on:
the original pressing, reissues, regional editions, compilations. They are returned in no
meaningful order, and they hold **different barcodes and different cover art**. Picking
arbitrarily therefore produces a per-track answer where the user sees a per-album fact.

The release is now chosen deliberately and stored in `musicbrainz_release_id`, which makes
the decision auditable instead of inferable from a barcode. Three rules: an album agrees
with itself (read from Postgres, so the agreement survives a restart); a release naming the
track's own album beats a compilation it also appears on; and among those, prefer one Cover
Art Archive actually holds a cover for, then the earliest, then the lowest id.

After the repair, cover coverage went 104 → 119 of 150 and *Dark Matter* is uniform. Seven
albums still span more than one release, and the reason is worth keeping: a widely reissued
album has dozens of pressings, and MusicBrainz lists for each recording only the ones it
appears on, so the release the first track settles on may simply not be among the fifth
track's options. Their covers agree; their barcodes do not. Resolving the **album** once and
mapping its tracks onto it would fix that, and is a larger piece of work than it sounds.

Two lessons, both general:

  * **A field filled correctly per row can still be wrong per album.** Nothing in the
    matching corpora would ever have caught this, because it is not a matching error — every
    one of those recordings was identified correctly.
  * **"Fill gaps, never correct" means a wrong value is permanent** until something explicitly
    clears it. `Enrichment.reset/1` is that something, and it is deliberately narrower than the
    repair this needed: it clears a barcode and cover only where `musicbrainz_release_id` proves
    enrichment chose the release they came from. The wider one-off clear lives in
    `dev/probes/repair_release_choice.exs`, where the argument for its safety is written down
    because it does not generalise.

### An ISRC MusicBrainz has never seen, and why `:high` was not enough

Found by looking at a playlist. *Throw Your Arms Around Me* from *Crucible* was reported as
not found, and MusicBrainz demonstrably holds it. Three separate causes, worth separating:

  1. **MusicBrainz does not index every ISRC.** `AULI01387660` is a perfectly good code from
     a 2013 Australian release and MusicBrainz has no such recording. Seven of the ten
     recordings it could not identify were of this kind.
  2. **Enrichment gave up there.** The identifier path answered "nothing" and the search path
     was only ever reached by a recording with *no* ISRC at all. It now falls through.
  3. **The library's own credit was wrong**, and this is the interesting one. *Crucible* is a
     tribute album — each track a different artist covering Hunters & Collectors — and the
     imported metadata credits every track to Hunters & Collectors, the album's *subject*.
     TIDAL has track 2 as **Neil Finn & Eddie Vedder, 238s**; MusicBrainz has exactly that
     recording, on a release called *Crucible*. Neither is findable from the wrong credit.

That third one is a limit on what any enrichment can do: a search is only as good as the
credit it is given, and no amount of scoring recovers a performer the source never recorded.

#### `:high` does not mean corroborated

The search path first ran at `:high`, justified by `Strategy.Text` scoring an uncorroborated
match at `0.89` against a `0.90` threshold. **The justification was wrong.** Searching for
*Throw Your Arms Around Me* by *Hunters & Collectors* returns the original band's own
recordings, and one scored **`0.9139`** — over the threshold — on an exact title and an exact
credit alone, with a different album and no duration to compare. An exact credit by itself
lifts text well clear of `0.90`.

Measured over all ten:

| | Score | Album agreed | Correct |
| --- | --- | --- | --- |
| Better Days | `0.98` | yes | yes |
| Brother the Cloud | `0.98` | yes | yes |
| Invincible | `0.98` | yes | yes |
| Long Way | `0.98` | yes | yes |
| Throw Your Arms Around Me | `0.9139` | **no** | **no** |
| Five others | — | — | correctly declined |

So the threshold is the **top of the `:text` band**, which `Matching.Confidence` defines as
"every compared field agreed after normalization", read from the band rather than written as
`0.98`. A number picked to separate five cases is tuning; a number that means *the ladder had
nothing left to disagree about* is a specification. Re-measured with it: **4 identified, all
correct, and the wrong one declined.**

#### Rejected: distrusting a candidate whose ISRC differs

The obvious alternative, and the fourth negative result of this kind here. When a recording
carries an ISRC MusicBrainz has never seen, a candidate carrying a *different* ISRC looks like
positive evidence of being a different recording.

It is not. MusicBrainz indexes recordings per release, so the same performance legitimately
carries a different code on whichever pressing it holds. Rejecting those made three of the four
correct answers **worse** — swapping *Earthling* for *Earthling Expansion: The Adventurous
Cuts* — and did nothing at all for the wrong one.

#### The query is not the stored strings — and the CSV was not the bug

Two recordings returned **zero** candidates, and the first diagnosis of that here was wrong
twice over. It blamed the credit being one string, `"Nusrat Fateh Ali Khan, Eddie Vedder"`,
and proposed splitting it in `Formats.CSV`. Both halves were mistaken:

  * **Matching was never affected.** `Normalize`'s `@punctuation_separators` is
    `/\s*[,&\/+]\s*/`, so the engine has always read that credit as two names. The stored
    string is only a problem for the *search query*.
  * **Splitting it on import would be destructive.** `Formats.CSV` splits on `;` and nothing
    else, deliberately and with the reason written down: a comma is a real character in
    *Earth, Wind & Fire*, *Tyler, The Creator* and *Crosby, Stills & Nash*. Splitting at
    read time would corrupt those permanently, where splitting at query time cannot — a bad
    query returns candidates that fail to corroborate and are declined.

Measured across the six recordings still unidentified:

| Query | Identified |
| --- | --- |
| The stored title and the stored credit | 0 |
| The **parsed** title, stored credit | 0 |
| The parsed title **and** the credit's first name | **2**, both at `0.98` |

Neither change works alone. A stored title carries in parentheses what MusicBrainz keeps out
of the title entirely — *"The Face Of Love (with Eddie Vedder)"* matches no recording, *"the
face of love"* matches it exactly — and `Normalize.title/1` already parses that, returning
`featuring: ["eddie vedder"]` alongside. Nothing is lost by querying the parsed form: the
ladder still scores the *raw* track, so a stripped version marker still applies to whatever
comes back, and the two recordings whose queries broadened were both correctly declined.

A search that comes back **empty** is then retried with the credit's first name. Empty rather
than unconvincing: an empty answer says the *question* was wrong, while a search that found
candidates and declined them was asked a good question and given a bad answer.

The general lesson: **normalization belongs on the way out, not on the way in.** The stored
value is the source's and has to survive; the query is ours and can be rebuilt any number of
ways.

### Cover art belongs to the album, not to the pressing

Found by looking at the playlist: fully enriched tracks with an ISRC and a barcode showing no
cover, on albums that certainly have one.

Enrichment asked whether the release it had chosen **for the barcode** held a front cover. That
is the wrong question, and obviously so once stated: which pressing wins a barcode has nothing
to do with which pressing somebody uploaded a scan for. Measured on *Pearl Jam* (2006) — of six
releases in the group, **three have a cover and three do not**, and the one chosen for its
barcode was among the three that do not.

A cover belongs to a **release group**, which is MusicBrainz's model of an album across all its
pressings. Asking the group is correct, and also cheaper: one question per album rather than one
per pressing, and the group id arrives free in the recording lookup by adding `release-groups`
to the `inc` list. Cover Art Archive answers for a group directly, so
`OnePlaylist.CoverArt.Client` replaced the release check entirely and the release-preference rule
that existed to find artwork was deleted — it was spending a request per candidate on a question
that belonged elsewhere.

The archive gets **its own `ExternalService`** rather than sharing MusicBrainz's, per `CLAUDE.md`'s
one-per-provider rule, and the reasons are real rather than formal: it publishes no
one-per-second limit, it redirects to archive.org so a call is two round trips through a CDN,
and its failures cost a thumbnail where MusicBrainz's cost a transfer.

Two lessons worth keeping:

  * **The second bug was in the repair, not the code.** The earlier release-selection repair
    detected an album as broken when *some* of its tracks had art and others did not. An album
    where **none** did looked consistent and was never re-run, leaving 48 rows still holding
    pre-`choose_release` metadata. A detector written from the symptom missed the worse case of
    the same fault.
  * **A cosmetic failure that is silent is not cosmetic.** The first whole-library run against
    the new client produced **no covers at all**, and nothing said so: `CoverArt.Service` had
    been added to the supervision tree but the dev node predated it — code reloading does not
    start supervision children — so every call answered `ServiceNotStarted`. No job failed, and
    `enriched_at` was stamped regardless, which made a transient outage permanent because
    `due/1` never offers a stamped recording again. `enrich/1` now distinguishes *the archive
    says there is no cover* (`404`, a complete attempt) from *the archive could not be asked*
    (an incomplete one): it keeps what it learned and leaves the recording due.
  * **Checking a constructed URL should not fetch it.** Asking Cover Art Archive for a release
    group's JSON index redirects to `archive.org` and then to a storage node — measured at
    **4091 ms** against **144 ms** for a `HEAD` on the image URL with redirects not followed,
    where `307` and `404` are the whole answer. That redirect chain was also the source of the
    `Req` transport timeouts the logs were full of.
  * **A URL is better provenance than an inference.** `Enrichment.reset/1` clears a barcode
    based on `musicbrainz_release_id` being set, which is a proxy and imperfect. For artwork it
    needs no proxy at all: a cover this application fetched carries the archive's host and one
    from TIDAL does not. Verified on the repair — 116 archive covers cleared, all 7 TIDAL covers
    kept.

### The album is the best term a MusicBrainz query has

A hand-labelled corpus, `dev/Unmatched PJ Favorites.csv`: twelve library recordings
MusicBrainz could not identify, nine with the recording they *should* have resolved to and
three marked as genuinely absent. Replayable with
`bin/remote dev/probes/replay_unmatched_corpus.exs`.

The first question to ask of a miss is which kind it is, and it had never been asked of
MusicBrainz:

  * **Not offered** — the search never returned the right recording. No scoring change can
    help; the query is wrong.
  * **Offered and declined** — it was in the candidate list and did not reach the threshold. No
    query change can help.

Four were offered and declined; **five were never offered at all**. And the cause is
structural rather than incidental: a prolific artist has more recordings of a title than a
page of results can hold. Pearl Jam has a bootleg of nearly every song from nearly every show,
so `recording:"Yellow Ledbetter" AND artist:"Pearl Jam"` has hundreds of true matches and
relevance buries the one on *Lost Dogs*.

| | Wanted recording found |
| --- | --- |
| Title and artist, ten results | 1 of 6 |
| Title and artist, **a hundred** results | 3 of 6 |
| Title, artist **and release** | **5 of 6**, four ranked first |

A bigger page is the obvious fix and the weaker one — it found three, two at #3 and #84, where
the ladder still has to pick out of noise. Naming the release finds five and puts them at the
top. The release term is unquoted deliberately: a stored album is routinely *longer* than the
release MusicBrainz holds — *Lost Dogs: Rarities and B Sides* against *Lost Dogs*, *Touring
Band 2000 - Instrumentals* against *Touring Band 2000* — and a phrase query matches in neither
direction.

#### Rejected: trusting a release-qualified candidate more

The argument was good and the measurement killed it, which makes this the fifth negative result
recorded here. A candidate found by a release-qualified query has had its album corroborated by
MusicBrainz's own index, so the ceiling — which exists to demand corroboration — looked like it
was asking for the same evidence twice. Dropping to `:high` for that path only:

| | correct | missed | wrong |
| --- | --- | --- | --- |
| At the ceiling | 3 | 9 | **0** |
| Release-qualified at `:high` | 6 | 3 | **3** |

Three gained and three wrong, including a recording matched to something for a track the label
says has **no** MusicBrainz recording at all. The flaw is in the premise: the release term
matches on *tokens*, so *Lost Dogs: Rarities and B Sides* reaches a great many bootlegs and the
corroboration is far weaker than it looks.

#### Rejected: an album's "core" as a matching signal

The sixth negative result here, and the idea was a good one. A stored album is routinely the
catalogue's title plus an annotation, and `Similarity.jaro_winkler/2` reads that **backwards**:
it rewards a shared prefix and penalises length difference, so measured against a real library —

| stored | release | similarity | corroborates at `0.9`? | should? |
| --- | --- | --- | --- | --- |
| Lost Dogs: Rarities and B Sides | Lost Dogs | `0.860` | no | **yes** |
| rearviewmirror (greatest hits…) | Rearviewmirror | `0.874` | no | **yes** |
| Vitalogy [2011 Reissue] | Vitalogy | `0.876` | no | **yes** |
| **Greatest Hits Vol. 2** | **Greatest Hits** | `0.937` | **yes** | **no** |

A *short wrong* suffix agrees and a *long right* one does not, so no threshold separates them.
`Normalize.album/1` — strip what follows a subtitle delimiter — looked like the answer.

Measured against the twelve labelled cases, it is not. Treating core equality as album agreement
converted misses into **wrong answers** rather than correct ones: with a spaced hyphen among the
delimiters, `+2 correct, +2 wrong`; narrowed to colons and brackets, `+0 correct, +1 wrong`,
against a baseline of zero wrong. Both corpora (`replay.exs`, `replay_credit_cases.exs`) were
unchanged throughout, so this is not a regression the general corpora would have caught — it is
specific to the case the rule was written for.

The narrowing is itself worth keeping: **a spaced hyphen is not a subtitle delimiter.** It is the
"Artist - Album" separator at least as often, and stripping at it turned the store-invented
bucket *Pearl Jam - Non-Album Tracks* into *Pearl Jam* — a real album, whose identity and cover a
pseudo-album then adopted.

So `Normalize.album/1` exists and is used in **`Enrichment.same_album?` only**, where the cost of
being wrong is a cover rather than an identity and the recording has already been identified by
other means. The matching ladder still compares album titles as it did.

#### What is left, and why it is not a threshold

Recall is now fixed and **nothing converted**: the right candidate is offered, ranked first, and
declined. The blocker is that the stored album is a disc subtitle MusicBrainz does not use, so
the ceiling's "every compared field agreed" can never be satisfied.

The tempting move is a threshold between the `0.9637` those score and whatever the wrong answers
score. That is tuning to twelve cases, which this project has rejected four times before. The
honest fix is in **normalization** — deciding when *Touring Band 2000 - Instrumentals* and
*Touring Band 2000* are the same album — and it needs its own corpus, because the same rule
would make *Greatest Hits* and *Greatest Hits Vol. 2* the same album too.

### Two bugs a real re-import found, both about the cost of being wrong

A user deleted a 143-track playlist and re-added it, and the screen showed things the tests
did not: covers from the wrong album, and a track that had simply disappeared.

**A release may only describe the album it is a release of.** `choose_release/2` *preferred* a
release whose title matched the recording's album and fell back to "the earliest" when none
did — so seven *Vs.* recordings were described by a release titled **Vitalogy** and showed
Vitalogy's cover. Three release groups were each serving two different albums. Rule 1 then
propagated the bad choice to every sibling, because it checked only that the release was in the
sibling's list. The fix is a filter rather than a preference, and rule 1 re-checks what it
inherits.

The cost is real and is asserted in a test: an album carrying a subtitle the catalogue does not
use — *Lost Dogs: Rarities and B Sides* against *Lost Dogs* — now matches no release and gains
no barcode or cover. That is the same album-normalization problem the MusicBrainz query section
ends on, and it errs toward showing nothing over showing another album's cover.

**Deduplication needs two exact keys, not one.** Matching at identifier strength fixed the
merging and broke something else: an ISRC-less track can never be *recognised* on its second
arrival, so re-importing a playlist grew a second copy of every one of them. Roughly 40% of a
real self-hosted library carries no ISRC, so "identifiers only" is not the safe direction it
looks like — it is a slower kind of wrong.

`find_or_create/1` now has a second key for tracks with no ISRC: the title, the album **and**
the credit all agreeing after normalization. What matters is that it is *exact equality rather
than similarity*, not which fields it uses — the two studio sessions of *Hard to Imagine*
disagree about the album and stay apart, while the same track imported twice is recognised.
Credits are compared as a set, so a service that orders a collaboration differently is still
the same credit. Verified by re-running a real 153-track import: the second run added **nothing**.

**A destination that accepts anything is matched at identifier strength.** *Hard to Imagine*
appears twice in that playlist — once from *Lost Dogs*, once from the *Chicago Cab*
soundtrack, two separate studio sessions. The second matched the first at `0.8950` on a shared
title, was reported `already_present`, and vanished. *Wishlist* from a 2006 bootleg merged into
the studio recording on *Yield* at `0.8734`.

The threshold that is right for a catalogue is wrong for the library, because the cost of being
wrong inverts:

| | A wrong match costs |
| --- | --- |
| Against a catalogue | one row in one report — visible, correctable, confined to that transfer |
| Against the library | **two recordings merged** — the track stops existing as itself, every playlist naming it now points at the other, and there is no split to undo it |

This is the same asymmetry the identity spine turns on, and it had been sitting in the transfer
path unnoticed since the library became a destination. `Library.find_or_create/1` was already
carefully conservative about what counts as the same recording — but it is only reached once
matching has *failed*, so a permissive ladder in front of it undid the care behind it.

Worth generalising: **`accepts_any_track` inverts more than what a miss means.** It was
introduced as "a failed match is an instruction to store", and it turns out also to change what
a *successful* match is allowed to conclude.

### An identifier can be wrong in the source

The ladder treats an exact ISRC as its strongest rung and takes the answer on trust. That is
right about ISRCs and wrong about *this ISRC*, because the code can be wrong before it ever
reaches us.

Found on a real library. A Roon export gave the *Vs.* tracks **Vitalogy's** ISRCs, so `Blood`
carried `USSM11100233` — which MusicBrainz resolves, correctly, to *Pry, To*. The matching was
right and the answer was wrong, and enrichment then wrote that identity down as a permanent
fact for every future transfer to rely on. Six of the twelve *Vs.* tracks were affected.

So an identifier's answer has to survive one question: **is this the same piece of music at
all?** Not "is this a good match" — a much lower bar, and the measurement says the two are far
apart:

| | Title similarity |
| --- | --- |
| Every exact-identifier pair in the captured corpus (93 of them) | `1.0` |
| The six wrong identities in a real library | `0.389` – `0.600` |
| The lowest *legitimate* disagreement — "The Long Road" against "Long Road" | `0.805` |
| *Sgt. Pepper's* against *Sergeant Pepper's* | `0.825` |

Nothing at all falls between `0.600` and `0.805`, so the floor goes in the **middle of the gap**
rather than against either edge — a floor at either edge would be tuned to whichever side had
been measured more carefully.

Measured effects, and the reason this was cheap to be sure about:

  * `replay.exs` **82/12/5/1** and `replay_credit_cases.exs` **96/12/7 with no false positives** —
    both byte-identical, because the guard applies to enrichment's *identifier* path and not to
    the ladder.
  * Of 133 identified recordings in a real library, **6 refused and 0 wrongly refused.**
  * A recording found by *search* is deliberately exempt: the ladder has already scored it at
    the text ceiling, and re-checking the title could only reject something accepted on better
    evidence.

One limit, stated rather than discovered later: a **cross-script** title — *Симфония №5* against
*Symphony No. 5* — scores `0.464` and would be refused. That is a real recording wrongly
declined. It fails toward declining rather than mis-identifying, which is the right direction,
and it is the strongest argument for eventually comparing something other than the strings.

The screen says *"this track's ISRC names a different recording"*, which is the diagnosis rather
than a symptom — and it points at the source data, which is where the fix has to happen.

### Is MusicBrainz the right catalogue to lean on?

Asked while building L4, and worth recording because the answer is not obvious.

| Source | Coverage | Terms | Verdict |
| --- | --- | --- | --- |
| **MusicBrainz** | ~2M releases, ~35M recordings; strong on ISRCs, works, relationships | CC0 data, free API at 1 req/s, **full Postgres dumps with hourly replication** | In use |
| Discogs | Deepest on pressings, labels and physical releases | Free API, 60 req/min authenticated | Complementary, not a replacement — no ISRCs, no works |
| Spotify / TIDAL / Apple | Excellent on what they carry | Tied to a user connection, terms forbid building a catalogue | Already used, as *providers* |
| AcoustID / Chromaprint | Identifies audio by fingerprint | Free | Needs the audio, which this application deliberately never has |
| Gracenote, Rovi/TiVo, TheAudioDB | Commercial, broad | Licensed, priced per seat | Not proportionate |

MusicBrainz is the right choice for this application, and the reason is the works and the ISRC
relationships rather than the size: those are what §2's classical work and the reissue family
rungs are built on, and no free alternative has them at all.

The rate limit is worth reading correctly, though. **One request a second is a policy on the
public web service, not a property of the data.** MetaBrainz publishes the whole database as
Postgres dumps with hourly replication, so an enrichment backlog that ever became the binding
constraint is answered by hosting a mirror rather than by finding another vendor. That is a
scaling option this project has and has not needed: 141 recordings enrich in under four minutes.

### My Playlists: one page, several origins

Grouped by where a playlist is stored: one group for the library, one per connected service.

The cost is not in the library half. Listing a user's playlists at *N* services is *N*
independent, rate-limited, individually-failing reads — 216 playlists at TIDAL is 11 requests
before anything renders. So each group loads independently and says so, in the shape
`TransferLive.New` already uses (`assign_async/3` per source), and one service being down or
rate-limited degrades its own group rather than the page.

### What this is deliberately not

  * **Not a player.** No audio, ever. The library holds metadata about recordings, which is also
    why it raises no licensing question at all — an important thing to be able to say plainly.
  * **Not a catalogue.** It holds what users have put in it, not the world's music. It has no
    ambition to be MusicBrainz and every reason to lean on it.
  * **Not social.** No sharing, no following, no public profiles. Each of those is a different
    product with a different threat model.

### What it raises that transfer never did

Transfer is stateless about user content: lose every row and a user re-runs a transfer. A
library is the opposite — it is the thing a user would be angriest to lose — and that raises the
bar in ways worth naming before building:

  * **Export must be complete and easy.** A library nobody can leave is a hostage. L6 is not a
    nice-to-have; it is the thing that makes L1 acceptable to depend on.
  * **Deletion must be real.** Deleting an account deletes its playlists.
  * **Backups become a product concern** rather than an operational one.
  * **Bidirectional sync becomes a genuine question.** Today sync has a source and a
    destination. A library playlist synced with a service playlist that both sides can edit
    needs a conflict answer, and "last writer wins" quietly loses somebody's edit. Soundiiz
    sidesteps this by making sync one-directional (§1); doing better is possible and should be a
    deliberate decision rather than an accident.
