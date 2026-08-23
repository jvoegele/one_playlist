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

  Was a map declared here *and* in `OnePlaylist.Providers.Tidal.OAuth`, with the
  two declarations disagreeing about which keys were optional. See
  `OnePlaylist.Providers.Tokens` for what that cost and why it is a struct.
  """
  @type tokens :: Tokens.t()

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

  Two clauses, and the reason they are both spelled out here rather than
  delegated to `OnePlaylist.Providers.Tokens`' invariant is worth recording,
  because an earlier version of this comment got it wrong.

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
  than going through `Tokens.new/1` is exactly the case this covers — and the
  case the previous arrangement silently did not.
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
  The provider ids of the tracks a playlist already contains, in order.

  The snapshot an idempotent transfer diffs against. `docs/reference/domain.md`
  requires that a retried transfer must not duplicate, and the only way to keep
  that promise is to look before writing.
  """
  # These ids are not data to display, they are **identity keys**: `Runner`
  # builds a `MapSet` from them and tests `match.track.provider_id` for
  # membership to decide whether a track needs writing. So an id that is not a
  # usable key does not fail — it answers the membership question wrongly, in
  # whichever direction is worse:
  #
  #   * a blank or mistyped id that should have matched reads as *absent*, and
  #     the track is written again — a duplicate in somebody's playlist that no
  #     later run can tell from one they added themselves;
  #   * a blank id that collides with a blank `provider_id` reads as *present*,
  #     and the track is silently never written at all.
  #
  # Both break the idempotency promise `docs/reference/domain.md` makes, and
  # neither raises. `to_string(nil)` is `""`, which is the realistic way a
  # provider omitting an id arrives here rather than a hypothetical one.
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
