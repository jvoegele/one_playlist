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
    * **Search** — the matching engine will need it and will define its shape.

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

  @doc false
  # Silences "unused alias" while keeping the aliases meaningful in the specs
  # above, which is where they earn their place.
  def __types__, do: {Playlist, Track, Connection}
end
