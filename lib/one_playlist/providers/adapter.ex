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
    * **Writes** — creating playlists, adding tracks. Not built yet for anyone.

  Adding a callback later is cheap. Removing one that turned out to encode
  TIDAL's assumptions is not.

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

  @default_search_limit 10

  @typedoc "A fresh token set from the provider."
  @type tokens :: %{
          required(:access_token) => String.t(),
          required(:expires_at) => DateTime.t(),
          optional(:refresh_token) => String.t() | nil,
          optional(:scopes) => [String.t()]
        }

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

  The two postconditions are the whole reason this callback is contracted. A
  refresh that returns an already-expired token, or a blank one, is worse than a
  failed refresh: it is stored, looks healthy, and fails at the next call with
  an error that points at the wrong thing.
  """
  @pre present: is_binary(refresh_token) and refresh_token != ""
  @post whenever({:ok, tokens} <- result),
    usable: is_binary(tokens.access_token) and tokens.access_token != "",
    fresh: DateTime.after?(tokens.expires_at, DateTime.utc_now())
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
