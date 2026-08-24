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

  @doc """
  A client for calls made with the application's own publishable key.

  `{:error, :not_configured}` rather than a raise, so a caller can report the
  fresh-checkout case at the sign-in form instead of crashing a request.
  Distinguishing "not configured" from "configured and failing" matters: they
  are different problems with different fixes.
  """
  @spec client() :: {:ok, Supabase.Client.t()} | {:error, :not_configured}
  def client do
    config = Application.get_env(:one_playlist, __MODULE__, [])
    base_url = config[:base_url]
    api_key = config[:api_key]

    if present?(base_url) and present?(api_key) do
      Supabase.init_client(base_url, api_key, %{})
    else
      {:error, :not_configured}
    end
  end

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
