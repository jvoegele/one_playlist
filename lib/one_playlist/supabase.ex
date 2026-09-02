defmodule OnePlaylist.Supabase do
  @moduledoc """
  Builds the Supabase client this application talks to GoTrue and Storage
  through.

  A function, not a process. Its two callers are `OnePlaylist.Accounts` and
  `OnePlaylist.Storage`, each the only module in its context that touches the
  SDK; everything else goes through one of them.

  ## Why there is no Agent here

  `supabase_potion` offers a module-based client that holds a
  `Supabase.Client` struct in an `Agent`, and `docs/reference/supabase.md`
  recommended it. It is deprecated as of 0.8, and the deprecation notice is a
  **security** warning rather than a style note:

  > This pattern causes race conditions and security vulnerabilities in
  > multi-user server environments where multiple requests share the same Agent
  > state. User tokens can become mixed, allowing User A to access User B's data.

  The mechanism is `set_auth/2`, which writes a user's access token into the one
  shared struct every concurrent request then reads. In a Phoenix application
  serving many users that is not a hazard to be careful around — it is a data
  breach waiting for a second simultaneous request.

  Building the struct per call removes the shared state rather than guarding it,
  which is the only version of this that stays correct when somebody later adds
  a caller without reading this comment. It is a cheap struct build over config
  already in memory, so there is nothing to amortise.

  ## It holds the publishable key, never the service role key

  The configured `api_key` is the **anon / publishable** key. That is not a
  detail to be relaxed later: the service role key carries
  `role: "service_role"`, which Postgres grants `BYPASSRLS`, so a request made
  with it ignores every policy in `priv/repo/migrations`. Signing a user in with
  it would authenticate anybody as anybody.

  The publishable key is designed to be exposed — it ships inside browser
  bundles — and by itself grants nothing RLS does not already allow. It is kept
  out of the repository anyway, per the habit `CLAUDE.md` describes.

  ## Configuration

      config :one_playlist, OnePlaylist.Supabase,
        base_url: "http://127.0.0.1:54321",
        api_key: "<publishable key>"

  Locally both come from `config/dev_local.exs`; in production from
  `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`, assigned in
  `config/runtime.exs`.
  """

  @typedoc """
  Which flow GoTrue's redirect-based sign-ins should use. See `client/1`.
  """
  @type flow_type :: :implicit | :pkce

  @doc """
  A client for calls made with the application's own publishable key.

  `{:error, :not_configured}` rather than a raise, so a caller can report the
  fresh-checkout case at the sign-in form instead of crashing a request.
  Distinguishing "not configured" from "configured and failing" matters: they
  are different problems with different fixes.

  ## `flow_type`

  The SDK reads `client.auth.flow_type` to decide whether a redirect-based
  sign-in — OAuth, magic link, sign-up confirmation, password recovery — should
  attach a PKCE challenge. The default here is the SDK's own, `:implicit`, and
  **only `OnePlaylist.Accounts.begin_google_sign_in/1` asks for `:pkce`**.

  That narrowness is deliberate and not a default worth relaxing. In 1.0.0 the
  SDK generates a verifier for every PKCE flow but returns it from
  `sign_in_with_oauth/2` alone; `sign_in_with_otp/2`, `sign_up/2` and
  `reset_password_for_email/3` discard it (see `docs/supabase-sdk-issues.md`).
  A magic link or confirmation email sent through a `:pkce` client would
  therefore carry a code nobody can exchange, and the user would be locked out
  by a link that looks correct. Setting `:pkce` on the shared client would break
  sign-up confirmation the day it is switched on in production.
  """
  @spec client(flow_type: flow_type()) ::
          {:ok, Supabase.Client.t()} | {:error, :not_configured}
  def client(opts \\ []) do
    config = Application.get_env(:one_playlist, __MODULE__, [])
    base_url = config[:base_url]
    api_key = config[:api_key]
    flow_type = Keyword.get(opts, :flow_type, :implicit)

    if present?(base_url) and present?(api_key) do
      with {:ok, client} <- Supabase.init_client(base_url, api_key, %{}) do
        {:ok, put_flow_type(client, flow_type)}
      end
    else
      {:error, :not_configured}
    end
  end

  # Set after the fact rather than passed to `init_client/3`, because the SDK's
  # typespec for its options cannot be satisfied: `Supabase.Client.options()`
  # declares `auth` as a map with every one of six keys *required* and
  # `flow_type` as a `String.t()`, while the runtime casts a partial map and
  # the documented call is `auth: [flow_type: :pkce]`. Passing either form
  # makes Dialyzer collapse this function to `{:error, _}` and flag every
  # caller's `{:ok, _}` branch as unreachable — 45 findings from one line.
  # See docs/supabase-sdk-issues.md. `struct!/2` is typed loosely enough that
  # the atom survives the `Supabase.Client.t()` in this module's own spec.
  defp put_flow_type(client, :implicit), do: client

  defp put_flow_type(client, flow_type),
    do: %{client | auth: struct!(client.auth, flow_type: flow_type)}

  @doc """
  A client that acts as a specific signed-in user.

  The access token replaces the publishable key in the `Authorization` header,
  which is what makes GoTrue treat the call as that user's — and what will make
  PostgREST and Realtime apply `auth.uid()`-based policies as that user, when
  this application starts using them.

  Returned as a fresh struct rather than mutated into a shared one. That is the
  whole point of the module note above: the token belongs to one request.
  """
  @spec client_for(String.t()) :: {:ok, Supabase.Client.t()} | {:error, :not_configured}
  def client_for(access_token) when is_binary(access_token) do
    with {:ok, client} <- client() do
      {:ok, Supabase.Client.update_access_token(client, access_token)}
    end
  end

  @doc """
  Whether a usable Supabase configuration is present.

  Public because the sign-in UI asks it directly: a form that cannot possibly
  work should say so rather than accept a password and fail.
  """
  @spec configured?() :: boolean()
  def configured? do
    config = Application.get_env(:one_playlist, __MODULE__, [])
    present?(config[:base_url]) and present?(config[:api_key])
  end

  defp present?(value), do: is_binary(value) and value != ""
end
