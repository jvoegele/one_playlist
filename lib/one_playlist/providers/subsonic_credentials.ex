defmodule OnePlaylist.Providers.SubsonicCredentials do
  @moduledoc """
  What a person types in to connect a Subsonic-compatible server.

  An `embedded_schema` rather than a bare map, because this is the only provider
  whose connection details are *entered* rather than obtained from an OAuth
  round trip — so it is the only one where a typo is the expected failure and
  field-level errors are what the user needs back.

  ## The password is not a token, but it is stored in the token column

  A Subsonic credential is the account's actual password (see
  `OnePlaylist.Providers.Subsonic.Client`). It is `redact: true` here for the
  same reason `Connection.access_token` is: this struct passes through
  `handle_event`, `start_async` and any crash report along the way, and
  `inspect/1` on it must never print the password. `:redact` covers `inspect`;
  the LiveView is separately responsible for never echoing it back into the DOM.

  ## The server URL is the interesting field

  Every other provider's base URL is a compile-time constant. This one is
  whatever the user pastes, which makes it the one place where validation is
  doing real work rather than restating the type.

  > #### Why there is no `@invariant` here {: .info}
  >
  > This is a **filter** in Meyer's sense (*OOSC* §11.6), and its whole purpose
  > is to hold input that has not been validated yet. An invariant describing the
  > validated form — a usable base URL, a password present — would be false of
  > `%SubsonicCredentials{}`, which is exactly what `changeset/2` is handed by
  > default, so it would fail on the way *into* the function whose job is to
  > establish it.
  >
  > That is the base-case rule, and it is not a limitation to work around: a type
  > whose invalid state is its starting state cannot have that state as an
  > invariant. The guarantees belong on `apply/1`, which is the boundary where
  > the value stops being input and starts being a credential — and they are
  > postconditions there.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  @typedoc "Details entered to connect a Subsonic-compatible server."
  @type t :: %__MODULE__{}

  @primary_key false
  @derive {Inspect, only: [:server_url, :username]}
  embedded_schema do
    field :server_url, :string
    field :username, :string
    field :password, :string, redact: true
    field :display_name, :string
  end

  @required ~w(server_url username password)a
  @optional ~w(display_name)a

  @doc """
  Validates entered credentials, normalizing the server URL.

  Note what is *not* checked: whether the credentials work. Only the server can
  answer that, which is why `OnePlaylist.Providers.connect_subsonic/2` calls it
  before persisting anything.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credentials \\ %__MODULE__{}, attrs) do
    credentials
    |> cast(attrs, @required ++ @optional)
    |> update_change(:server_url, &normalize_url/1)
    |> update_change(:username, &String.trim/1)
    |> validate_required(@required)
    |> validate_server_url()
  end

  @doc """
  Turns a valid changeset into the struct, or returns the invalid changeset.

  `Ecto.Changeset.apply_action/2` with `:insert` is what marks the changeset as
  actioned, so `Phoenix.Component.used_input?/1` shows errors on a form that has
  only ever been submitted — this form deliberately has no `phx-change`, because
  validating on every keystroke would mean sending the password on every
  keystroke.
  """
  # This module is a **filter** in Meyer's sense (*OOSC* §11.6): it faces the
  # outside world, so it has no preconditions — a typo is the expected input, not
  # a caller's bug, and it comes back as a changeset rather than a violation.
  #
  # What a filter owes the processing modules behind it is the other half of that
  # arrangement: *its postconditions must match or exceed their preconditions*.
  # These two are that debt, stated.
  #
  # `usable_base_url` is what `OnePlaylist.Providers.Subsonic.Client` assumes
  # when it builds the request URL by concatenating `/rest/<endpoint>`. A trailing slash yields
  # `//rest/...`, which some Subsonic servers answer and others do not — a
  # failure that depends on which server the user happens to run. `Client` trims
  # defensively too, and that is belt-and-braces rather than the guarantee.
  #
  # `credentials_are_present` mirrors `Tokens`' `access_token_present`, and for
  # the same reason: the password becomes `Connection.access_token`, and
  # `Connection.usable?/1` answers `true` for `""` because an empty string is a
  # binary. A blank one therefore produces a connection that looks healthy and
  # 401s on every call — the exact shape this project is organised against.
  @post whenever(
          {:ok, credentials} <- result,
          usable_base_url: usable_base_url?(credentials.server_url),
          credentials_are_present:
            credentials.username != "" and credentials.password not in [nil, ""]
        )
  @spec apply(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def apply(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Whether a string is a server address `OnePlaylist.Providers.Subsonic.Client`
  can concatenate a path onto.

  Public because `apply/1` names it in a postcondition, and an assertion
  rendered into the documentation should reference something a reader can look
  up. It is also the honest statement of what this module promises the rest of
  the application about a validated server address.

      iex> alias OnePlaylist.Providers.SubsonicCredentials
      iex> SubsonicCredentials.usable_base_url?("http://music.local:4533")
      true
      iex> SubsonicCredentials.usable_base_url?("http://music.local:4533/")
      false
      iex> SubsonicCredentials.usable_base_url?("ftp://music.local")
      false
  """
  @spec usable_base_url?(term()) :: boolean()
  def usable_base_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != "" and not String.ends_with?(url, "/")

      _otherwise ->
        false
    end
  end

  def usable_base_url?(_url), do: false

  @doc """
  A name for the connection when the user did not supply one.

  The host, so a person with two servers can tell them apart in a list.
  """
  @spec default_display_name(String.t()) :: String.t()
  def default_display_name(server_url) when is_binary(server_url) do
    case URI.parse(server_url).host do
      host when is_binary(host) and host != "" -> host
      _no_host -> server_url
    end
  end

  # Trailing slashes are the classic self-hosted footgun — the user copies the
  # URL out of their browser's address bar, which adds one. `Subsonic.Client`
  # trims it too, defensively, but normalizing at the point of entry means the
  # stored value is the one the user will see echoed back.
  defp normalize_url(url) when is_binary(url),
    do: url |> String.trim() |> String.trim_trailing("/")

  defp normalize_url(url), do: url

  # A URL is rejected rather than repaired. Guessing a missing scheme is the
  # tempting shortcut and it is the wrong one in both directions: defaulting to
  # `http://` silently downgrades a server the user intended to reach over TLS —
  # and a Subsonic token is a salted MD5, which is replayable by anyone who can
  # read the request — while defaulting to `https://` fails to connect to the
  # local server that is the overwhelmingly common case, with an error that
  # blames the credential rather than the URL.
  #
  # > #### This is a request to an address the user chose {: .warning}
  # >
  # > Restricting the scheme to http/https closes off `file:`, `gopher:` and the
  # > rest, but it deliberately does **not** block private or loopback
  # > addresses: a self-hosted music server lives at `192.168.1.x` or
  # > `localhost`, so blocking those would be blocking the feature. The
  # > mitigations that remain are that the request is initiated by an
  # > authenticated user against their own stated server, carries no ambient
  # > credentials, and that nothing of the response reaches the user except a
  # > Subsonic envelope — a scan of an internal network would learn only
  # > "not a Subsonic server". Worth revisiting before this is hosted for
  # > strangers; see docs/reference/domain.md.
  defp validate_server_url(changeset) do
    validate_change(changeset, :server_url, fn :server_url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        # No host is almost always a missing scheme, and `URI.parse/1` disguises
        # it: `"localhost:4533"` parses with scheme `"localhost"` and no host at
        # all, so this case has to be checked before the scheme is judged or the
        # user is told their port is the wrong protocol.
        %URI{host: host} when not is_binary(host) or host == "" ->
          [server_url: "must start with http:// or https://"]

        %URI{} ->
          [server_url: "must be an http:// or https:// address"]
      end
    end)
  end
end
