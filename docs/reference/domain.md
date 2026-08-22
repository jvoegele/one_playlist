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

- **A barcode's album id is worth caching and never expires.** A barcode identifies a release
  permanently, so the mapping cannot become wrong — only incomplete, which a cache miss
  handles. It is also identical for every user, which makes it the compounding asset described
  above rather than per-user state. Tracks cluster into albums (38 distinct albums across the
  60-track corpus; 5 across an 8-track live sample), so caching removes most of the lookups.

  Worth being explicit, because the instinct is to reach for concurrency instead: running these
  requests in parallel reduces wall-clock while spending **exactly the same quota**, and the
  circuit breaker is shared across all users, so bursting catalogue reads degrades TIDAL for
  everyone. Fewer requests is the lever; faster requests is not.

**Rate limits are not published.** Community reports put 429s as common on catalog reads and
rare on playlist operations. With no documented quota the only safe posture is to stay well
under whatever it is — hence the deliberately conservative 8 calls/second in
`OnePlaylist.Providers.Tidal.Service`.

Tidal is **not** one of Supabase Auth's built-in social providers, so its OAuth flow is driven
by this application rather than by GoTrue. That is more code and a better outcome: the tokens
arrive directly instead of appearing once in a Supabase session and vanishing.

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
