defmodule OnePlaylist.Providers.Adapter do
  @moduledoc """
  What every music service adapter must provide.

  ## Why a behaviour, and why only these callbacks

  Normally one implementation is too few to abstract from — you end up encoding
  one provider's shape as though it were universal. Two things make this the
  exception. There *will* be more providers; that is the product, not a
  speculation. And there is already a dispatch on `provider` in
  `OnePlaylist.Providers`, which without this becomes a growing `case`.

  The callbacks are deliberately limited to operations already proven against a
  live service. Notably absent:

    * **The OAuth flow** — `authorization_url`, `exchange_code`. TIDAL, Spotify,
      Google and Deezer all use Authorization Code, so the shape looks obvious;
      Apple Music does not, since its Music User Token can only be obtained in a
      browser via MusicKit JS. One OAuth provider is not enough to know which
      parts of that are universal.

  Adding a callback later is cheap. Removing one that turned out to encode
  TIDAL's assumptions is not — which is why the write callbacks below are the
  smallest set that can express a transfer, and why `add_tracks/4` is specified
  as *append*, leaving deduplication to a caller that can see both sides.

  ## Contracts

  Contracts are declared here, on the callbacks, and enforced in every
  implementing module — see `Bond.Behaviour` and
  `docs/reference/jv-libraries.md`. An implementation gets them by writing
  `use Bond, behaviours: [OnePlaylist.Providers.Adapter]`, with no contract code
  of its own.

  > #### Streams cannot usefully be constrained {: .warning}
  >
  > `stream_playlists/2` and `stream_tracks/3` return *lazy* streams, so a
  > postcondition about their contents would have to consume them to check —
  > turning a lazy read into hundreds of HTTP requests, inside an assertion, on
  > every call. There is nothing to say about them beyond "it is an Enumerable",
  > which restates the `@spec`. Per Bond's own guidance on vacuous assertions,
  > they carry no `@post` at all.
  >
  > The token callbacks are the opposite case: eager, small, and with a real law
  > to state.
  """

  use Bond.Behaviour

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Tokens

  @default_search_limit 10

  @typedoc """
  A fresh token set from the provider.

  A struct rather than a map, so that every adapter and every consumer agrees
  about which keys exist — see `OnePlaylist.Providers.Tokens`.
  """
  @type tokens :: Tokens.t()

  @typedoc """
  Something a service can do that another cannot.

  Deliberately **only what varies**. Every adapter searches, creates a playlist
  and appends to it, so declaring those would be noise that has to be kept in
  step for no reader's benefit. A capability earns its place here when code has
  to know the answer *before* calling — which is the whole distinction between
  this and simply looking at what came back.

    * `:artwork` — tracks carry a cover image URL. TIDAL returns one in the same
      response as the track, through an `albums.coverArt` relationship, so it
      costs nothing. Subsonic's cover endpoint requires credentials on the
      request, so a URL from it could not be put in an `img` tag without leaking
      them; that is a design problem rather than a missing field, and until it
      is solved Subsonic honestly does not have this.

    * `:accepts_any_track` — this destination can hold a recording it does not
      already have, so `c:accept_track/3` will succeed. True of
      `OnePlaylist.Providers.Library` and of nothing else: TIDAL and Subsonic
      can only hold what their catalogues carry. Asked before calling because it
      changes what a *failure to match* means — against a destination that
      accepts anything, an unmatched track is not a track that cannot be
      transferred, it is one that has not been stored yet. See
      `docs/reference/domain.md` §5.

    * `:global_ids` — a track id from this provider means the same thing to
      every connection of it, so a track taken from one and handed to another is
      the same track. True of TIDAL, whose ids name entries in one catalogue
      shared by every account, and of `OnePlaylist.Providers.Library`, which is
      a single store.

      **Not** true of Subsonic, and that is the whole reason this exists rather
      than a comparison of provider names. Two Subsonic connections are two
      *different servers*: both say `:subsonic`, and an id from one names
      nothing on the other — or, far worse, names something else. Anything that
      reasons about "the same service" from the provider alone is wrong for
      every self-hosted provider this application will ever add.

      Asked before calling because it decides whether a search is needed at all:
      see `OnePlaylist.Transfers.Runner`.

    * `:remove_tracks` — a track can be taken *out* of a playlist, via
      `c:remove_tracks/4`. Both adapters can, so today this does not vary and
      nothing branches on it; it is declared because the question is asked
      *before* calling rather than after — `OnePlaylistWeb.TransferLive.Show`
      needs to know whether replacing a wrong match is possible before it
      offers the button. If a later adapter cannot remove, this is how it says
      so; if the answer stays universal, the rule above says retire it.
  """
  @type capability :: :artwork | :accepts_any_track | :remove_tracks | :global_ids

  @doc """
  What this service can do that others may not.

  Absent from the list means "no", so a new capability defaults to unsupported
  everywhere until an adapter claims it. That is the safe direction: the cost of
  wrongly claiming a capability is a call that fails against a live service.
  """
  @callback capabilities() :: [capability()]

  @doc """
  The provider this adapter serves.

  The postcondition is inherited by every adapter, so an adapter that reports a
  provider the schema has never heard of — a typo, or a rename that missed one
  place — fails at its own boundary rather than as a confusing constraint
  violation the first time someone tries to store a connection for it.
  """
  @post known_to_the_schema: result in OnePlaylist.Providers.Connection.providers()
  @callback provider() :: Connection.provider()

  @doc """
  Exchanges a refresh token for a new access token.

  The contract here is the whole reason this callback is contracted. A refresh
  that returns an already-expired token, or a blank one, is worse than a failed
  refresh: it is stored, looks healthy, and fails at the next call with an error
  that points at the wrong thing.

  Two clauses, and both are spelled out here rather than delegated to
  `OnePlaylist.Providers.Tokens`' invariant. The reason is easy to get wrong:

    * **`well_formed`.** A blank access token, or a blank refresh token that
      `Providers.refresh/1`'s `||` fallback would store over a working one.
      `Tokens` states this as an invariant too, but an invariant **cannot be
      reached from another module's assertion**: Meyer's Assertion Evaluation
      rule (*OOSC* §11.14) has calls made during assertion evaluation run with
      their own contracts suppressed, and Bond implements it. Measured, not
      assumed — `Tokens.fresh?/2` called from inside a `@post` returns a plain
      boolean where the same call outside one raises `Bond.InvariantError`.
    * **`fresh`.** Not an invariant at all — a token set is fresh when issued
      and stale hours later without changing. Only the producer can promise it.

  So the two surfaces need two assertions. `Tokens.well_formed?/1` is what keeps
  that from being two *copies*: it states the structural law once, in a form that
  answers rather than raises. An adapter that hand-builds `%Tokens{}` rather
  than going through `Tokens.new/1` is exactly the case this covers, and the
  case an invariant alone would silently miss.
  """
  #
  # `OnePlaylist.Providers.Tokens` is spelled out rather than using the `Tokens`
  # alias in scope above. An inherited contract's expression is injected into
  # each *implementing* module and resolved in that module's alias table, not in
  # this one — so the short form compiles here and fails in `Tidal` and
  # `Navidrome` with "module Tokens is not available", reported against a
  # generated function name at a line that is blank.
  @pre present: is_binary(refresh_token) and refresh_token != ""
  @post whenever({:ok, tokens} <- result),
    well_formed: OnePlaylist.Providers.Tokens.well_formed?(tokens),
    fresh: OnePlaylist.Providers.Tokens.fresh?(tokens)
  @callback refresh_tokens(refresh_token :: String.t()) ::
              {:ok, tokens()} | {:error, Exception.t()}

  @doc """
  The connected account, as the provider describes it.

  Doubles as a liveness check: the cheapest call that proves a token works.
  """
  @callback whoami(connection :: Connection.t()) :: {:ok, map()} | {:error, Exception.t()}

  @doc "The playlists the user owns, as a lazy stream of `Playlist`."
  @callback stream_playlists(connection :: Connection.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, Exception.t()}

  @doc "A playlist's tracks, in order, as a lazy stream of `Track`."
  @callback stream_tracks(
              connection :: Connection.t(),
              playlist :: String.t() | Playlist.t(),
              opts :: keyword()
            ) :: {:ok, Enumerable.t()} | {:error, Exception.t()}

  @doc """
  Candidate matches for `track` on this provider, for the matching engine.

  Returns candidates, not answers. Deciding which one — if any — is the same
  recording is `OnePlaylist.Matching`'s job, and keeping that decision out of
  the adapters is what stops each provider growing its own private notion of
  what "close enough" means.

  ## Options

    * `:limit` — the most candidates to return. Defaults to `limit/1`.

  Implementations should use the cheapest lookup that can answer. Where a
  provider offers an ISRC filter, that is one request returning exact
  candidates, and it is both cheaper and better than a text search.
  """
  # Searching for a track with neither an identifier nor a title cannot return
  # anything useful, and the cost of finding that out is a request against a
  # provider quota — 100 units of a 10,000/day budget on YouTube. Preconditions
  # stay enabled in production precisely so a caller's bug is named at the
  # boundary instead of quietly spending someone's daily allowance.
  @pre searchable: OnePlaylist.Matching.searchable?(track)
  @post whenever({:ok, candidates} <- result),
    # An adapter that labelled results with another provider's name would poison
    # every match cached from them — the resolution cache keys on
    # `(provider, provider_id)`, so the damage outlives the request that caused
    # it and reappears for every other user.
    all_from_this_provider: forall(candidate <- candidates, candidate.provider == provider()),
    # A provider that ignores the limit hands the matching engine thousands of
    # candidates to score. Nothing fails; a transfer just gets slower per track
    # until it looks like a hang.
    never_more_than_requested: length(candidates) <= OnePlaylist.Providers.Adapter.limit(opts)
  @callback search_tracks(connection :: Connection.t(), track :: Track.t(), opts :: keyword()) ::
              {:ok, [Track.t()]} | {:error, Exception.t()}

  @doc """
  Creates an empty playlist owned by the connected account.

  Returns the created playlist so the caller has its `provider_id`; there is
  nothing to add tracks to otherwise.
  """
  # A created playlist that cannot be addressed is worse than a failed creation:
  # the transfer proceeds, adds tracks to nothing, and reports success. The
  # provider is the only thing that can mint that id, so this is the boundary at
  # which its absence must stop being someone else's problem.
  @post whenever({:ok, playlist} <- result),
    addressable: is_binary(playlist.provider_id) and playlist.provider_id != "",
    from_this_provider: playlist.provider == provider()
  @callback create_playlist(connection :: Connection.t(), name :: String.t(), opts :: keyword()) ::
              {:ok, Playlist.t()} | {:error, Exception.t()}

  @doc """
  Appends tracks to a playlist, in the order given.

  Implementations **append and do not deduplicate**: deciding what to add is
  `OnePlaylist.Transfers`' job, because only it knows what the destination
  already held before this transfer began. See `playlist_track_ids/3`.

  Returns how many were added, which is what a transfer report counts.
  """
  # Conservation, at the one point in the application where being wrong writes
  # to somebody's music library. A provider that reported adding more than it
  # was given would inflate every report built on it, and the inflation would be
  # invisible — the numbers would simply agree with each other and disagree with
  # the playlist.
  @pre something_to_add: is_list(tracks)
  @post whenever({:ok, added} <- result),
    never_more_than_offered: added <= length(tracks),
    non_negative: added >= 0
  @callback add_tracks(
              connection :: Connection.t(),
              playlist :: String.t() | Playlist.t(),
              tracks :: [Track.t()],
              opts :: keyword()
            ) :: {:ok, non_neg_integer()} | {:error, Exception.t()}

  @doc """
  This destination's own representation of a track, storing it if need be.

  The callback behind `:accepts_any_track`, and the reason the library can be a
  transfer destination without every track arriving as `:unmatched`.

  Every other destination is a **catalogue**: it holds what it holds, a track it
  does not carry cannot be put there, and that is what a failed match means. The
  library is not — it can hold anything — so a match that finds nothing is not a
  dead end but an instruction to store the track and carry on.

  Returns a track belonging to *this* provider, with a `provider_id` that is
  addressable immediately. That is not a formality: `OnePlaylist.Transfers.Runner`
  diffs against `playlist_track_ids/3` and re-reads afterwards to confirm the
  write, so a returned track still carrying the *source's* id would be
  reported missing by its own confirmation step.

  Adapters that cannot do this return an error and declare no capability, rather
  than the callback being optional — the behaviour stays total, so "every
  adapter implements every callback" remains something the suite can check.
  """
  # Same shape as `create_playlist/3`'s `addressable`, and the same reason: a
  # value that cannot be addressed is worse than a failure, because the transfer
  # proceeds on it and reports success.
  @post whenever(
          {:ok, accepted} <- result,
          addressable: is_binary(accepted.provider_id) and accepted.provider_id != "",
          from_this_provider: accepted.provider == provider()
        )
  @callback accept_track(
              connection :: Connection.t(),
              track :: Track.t(),
              opts :: keyword()
            ) :: {:ok, Track.t()} | {:error, Exception.t()}

  @doc """
  Removes tracks from a playlist, returning how many entries went.

  **Every occurrence**, not the first. A playlist may legitimately hold the same
  recording twice, and the caller's question is "this should not be here" rather
  than "one of these should not be here" — so this is idempotent in the way
  `add_tracks/4` is not, and calling it twice is safe.

  ## Neither provider can do this by track id alone

  Verified live on 2026-08-24, and it is the reason this takes tracks rather
  than the ids `playlist_track_ids/3` returns:

  | | Removal is keyed on |
  | --- | --- |
  | TIDAL | the track id **and** `meta.itemId`, a per-item UUID. Sending either alone is a `400`. |
  | Subsonic | a zero-based **index** into the playlist, and no song id at all. |

  So an implementation has to read the playlist to find out what to say, which
  is a request it makes for itself rather than one the caller can save it. That
  read is also what makes a *stale* removal safe: positions and item ids are
  resolved in the same breath as the delete rather than passed in from
  somewhere older.

  **Removing nothing removes nothing.** That is the dangerous direction here, and
  the opposite of `c:add_tracks/4`'s: an implementation computing positions by
  *difference* rather than by membership answers "remove everything" when asked
  to remove nothing, and the symptom is somebody's playlist emptied by a no-op
  call. Appending an empty list, by contrast, appends nothing whatever the bug.

  There is deliberately no `removed <= length(tracks)` bound. Removing every
  occurrence of a track a playlist holds twice legitimately returns 2 for one
  track, so the real upper bound is the playlist's length, which this cannot see.
  """
  # Verified by mutation: turning `Tidal.remove_tracks/4`'s `Enum.filter` into an
  # `Enum.reject` — the difference-not-membership slip above — fires it on the
  # call that asks for nothing.
  @pre something_to_remove: is_list(tracks)
  @post whenever(
          {:ok, removed} <- result,
          non_negative: removed >= 0,
          nothing_asked_removes_nothing: (tracks == []) ~> (removed == 0)
        )
  @callback remove_tracks(
              connection :: Connection.t(),
              playlist :: String.t() | Playlist.t(),
              tracks :: [Track.t()],
              opts :: keyword()
            ) :: {:ok, non_neg_integer()} | {:error, Exception.t()}

  @doc """
  The provider ids of the tracks a playlist already contains, in order.

  The snapshot an idempotent transfer diffs against. `docs/reference/domain.md`
  requires that a retried transfer must not duplicate, and the only way to keep
  that promise is to look before writing.

  These are not data to display, they are **identity keys**:
  `OnePlaylist.Transfers.Runner` builds a `MapSet` from them and tests each
  match's `provider_id` for membership. So an id that is not a usable key does
  not fail — it answers the membership question wrongly, in whichever direction
  is worse. A blank or mistyped id that should have matched reads as *absent* and
  the track is written again, a duplicate no later run can tell from one the user
  added themselves; a blank id colliding with a blank `provider_id` reads as
  *present*, and the track is silently never written at all.

  Both break the idempotency promise, and neither raises.
  """
  # `to_string(nil)` is `""`, which is how a provider omitting an id realistically
  # arrives here rather than a hypothetical.
  @post whenever({:ok, ids} <- result),
    ids_are_usable_keys: forall(id <- ids, is_binary(id) and id != "")
  @callback playlist_track_ids(
              connection :: Connection.t(),
              playlist :: String.t() | Playlist.t(),
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, Exception.t()}

  @doc """
  How many candidates a search should return, from `opts`.

  Public because `search_tracks/3` names it in a postcondition, and an
  assertion rendered into the documentation should reference something a reader
  can look up.

  The default is deliberately small. Candidates past the first handful are
  almost never the answer, and every one of them is scored against the source.
  """
  @spec limit(keyword()) :: pos_integer()
  def limit(opts), do: Keyword.get(opts, :limit, @default_search_limit)

  @doc false
  # Silences "unused alias" while keeping the aliases meaningful in the specs
  # above, which is where they earn their place.
  def __types__, do: {Playlist, Track, Connection}
end
