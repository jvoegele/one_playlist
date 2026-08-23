defmodule OnePlaylist.Storage do
  @moduledoc """
  Playlist files in Supabase Storage.

  Holds the files a user uploads to import and the files this application
  generates to export. The only module that builds object paths, which is not a
  tidiness rule — see below.

  ## Every call acts as the user

  Storage is reached with the signed-in user's own access token, through
  `OnePlaylist.Supabase.client_for/1`, so the policies in
  `priv/repo/migrations/20260823120000_create_playlists_bucket.exs` apply to this
  application exactly as they would to a browser calling the REST API directly.

  That is the same choice `OnePlaylist.Repo.as_user/3` makes for Postgres, and
  it matters more here: `storage.objects` grants `authenticated` every
  privilege, Supabase having granted them, so the policies are the *only* thing
  between one user's uploads and another's. Using the service key would silently
  bypass all four.

  ## The path is the ownership model

  Objects live at `<user_id>/<kind>/<name>`, and the policies compare
  `auth.uid()` against the **first folder**. There is no owner column on
  `storage.objects` to key on — this is Supabase's own convention — so a path
  built anywhere else, with the segments in a different order, would be a
  security bug rather than a formatting one. `path_for/3` is the one place that
  builds them, and its postcondition states the law.

  ## What is stored, and why both directions

  Imports are kept rather than parsed and discarded, so a transfer can be re-run
  against the file it actually came from and a user can see what they uploaded.
  Exports need somewhere to live that survives a page refresh, which a streamed
  HTTP response does not.
  """

  use Bond
  use Errata

  alias OnePlaylist.Accounts.Session
  alias OnePlaylist.Storage.Unavailable
  alias Supabase.Storage.File, as: StorageFile

  require Logger

  @bucket "playlists"

  @typedoc "What a stored file is for. Becomes the second path segment."
  @type kind :: :imports | :exports

  @kinds [:imports, :exports]

  @doc """
  The bucket every playlist file lives in.
  """
  @spec bucket() :: String.t()
  def bucket, do: @bucket

  @doc """
  Where a file for this user, of this kind, is stored.

  The first segment is the user id because that is what the storage policies
  compare `auth.uid()` against. Nothing else may assemble one.

  The name is reduced to characters that need no URL encoding. That is partly
  principle — an object key and a filename a person reads are different things,
  and a key should be boring — and partly a workaround: `supabase_storage` does
  not encode the object path it builds, so a space produces a request Storage
  rejects. Verified directly against the API, where `%20` is accepted and a raw
  space is not. See `docs/supabase-sdk-issues.md`.

      iex> alias OnePlaylist.Storage
      iex> Storage.path_for("11111111-1111-4111-8111-111111111111", :imports, "Road Trip.csv")
      "11111111-1111-4111-8111-111111111111/imports/Road-Trip.csv"
  """
  # Not a restatement of the implementation. The law is that the *first segment
  # is the user id* — which is the entire access control model for these
  # objects — and a rewrite that put the kind first, or prefixed the bucket,
  # would satisfy the type and quietly file every user's uploads where the
  # policy cannot match them. That fails open on read (nothing matches, the file
  # looks missing) and closed on write.
  @pre user_is_identified: is_binary(user_id) and user_id != ""
  @pre known_kind: kind in @kinds
  @post owner_is_the_first_segment: hd(String.split(result, "/")) == user_id
  # Stated rather than left to the sanitiser, because the consequence of getting
  # it wrong is a request Storage rejects with a message about nothing in
  # particular. `~r/[A-Za-z0-9._~\/-]/` is the unreserved set from RFC 3986 plus
  # the separator, so nothing in a key ever needs escaping.
  @post needs_no_url_encoding:
          result == URI.encode(result, &(URI.char_unreserved?(&1) or &1 == ?/))
  @spec path_for(String.t(), kind(), String.t()) :: String.t()
  def path_for(user_id, kind, name) when is_binary(name) do
    Path.join([user_id, to_string(kind), safe_name(name)])
  end

  # Everything outside the unreserved set becomes a hyphen, and runs of hyphens
  # collapse so a name does not turn into punctuation. A name reduced to nothing
  # gets one, because an empty final segment is a path ending in `/`, which
  # addresses the folder rather than an object.
  defp safe_name(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9._~-]/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
    |> case do
      "" -> "file"
      safe -> safe
    end
  end

  @doc """
  Stores a file for the signed-in user, returning its path.

  `content` is written to a temporary file first: the Storage SDK uploads from a
  path rather than from memory. The temporary file is removed afterwards whether
  or not the upload succeeds — it holds a user's playlist, and `System.tmp_dir`
  is world-readable on a shared host.
  """
  # Sobelow flags the `File.rm/1` below as possible directory traversal, at low
  # confidence, because it cannot see where `tmp` comes from. It is
  # `System.tmp_dir!/0` joined with a freshly generated UUID: no argument to this
  # function reaches it, and `name` — the one value a user influences — goes into
  # `path_for/3` for the *object* path, never into the local one.
  #
  # Skipped rather than restructured, and skipped by name so every other
  # traversal finding in this file still fails the build.
  # sobelow_skip ["Traversal.FileModule"]
  @spec put(Session.t(), kind(), String.t(), iodata()) ::
          {:ok, String.t()} | {:error, Errata.Error.t()}
  def put(%Session{} = session, kind, name, content) do
    path = path_for(session.user_id, kind, name)
    tmp = Path.join(System.tmp_dir!(), "one_playlist-#{Ecto.UUID.generate()}")

    try do
      with :ok <- File.write(tmp, content),
           {:ok, storage} <- storage(session),
           {:ok, _uploaded} <- StorageFile.upload(storage, tmp, path) do
        {:ok, path}
      end
      |> classified(:put)
    after
      _ = File.rm(tmp)
    end
  end

  @doc """
  Reads a stored file back.

  Answers `:not_found` for somebody else's file just as it does for one that
  does not exist — not by choosing to, but because the select policy filters it
  out before Storage sees it, which is the behaviour worth having and the reason
  the policies are tested directly.
  """
  @spec get(Session.t(), String.t()) :: {:ok, binary()} | {:error, Errata.Error.t()}
  def get(%Session{} = session, path) do
    with {:ok, storage} <- storage(session) do
      StorageFile.download(storage, path)
    end
    |> classified(:get)
  end

  @doc """
  A time-limited URL a browser can download the file from.

  The bucket is private, so there is no public URL — a signed one is the only
  way to hand a file to a browser without proxying every byte through Phoenix.

  Signed for an hour by default. Long enough to click, short enough that a URL
  pasted into a chat or captured in a proxy log stops working before it is
  interesting.
  """
  @spec signed_url(Session.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, Errata.Error.t()}
  def signed_url(%Session{} = session, path, expires_in \\ 3600) do
    with {:ok, storage} <- storage(session) do
      StorageFile.create_signed_url(storage, path, expires_in: expires_in)
    end
    |> classified(:signed_url)
  end

  @doc """
  Removes a stored file.

  Answers `:not_found` when nothing was removed, which is what happens for a
  file belonging to somebody else: the delete policy's `using` clause filters
  the row out before the statement sees it, so Storage reports a perfectly
  successful deletion of nothing.

  That silence is the same asymmetry the Postgres policies have — `using`
  filters, `with check` raises — and it is worth converting into an answer
  here, because a caller that believes it deleted a file will not try again.
  Storage returns the list of objects it removed, so the empty case is
  distinguishable rather than merely suspected.
  """
  @spec delete(Session.t(), String.t()) :: :ok | {:error, Errata.Error.t()}
  def delete(%Session{} = session, path) do
    with {:ok, storage} <- storage(session) do
      StorageFile.remove(storage, path)
    end
    |> classified(:delete)
    |> case do
      # Storage answers with the objects it actually removed, so an empty list
      # is "the policy filtered it out" rather than "there was nothing to do".
      # Decided here rather than inside `classified/2` so the rule is visible at
      # the function it belongs to.
      {:ok, []} ->
        {:error, Errata.create(Unavailable, reason: :not_found, context: %{operation: :delete})}

      {:ok, _removed} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  # Every public function above funnels its result through here, so the mapping
  # from "what the SDK said" to "what a caller can act on" is written once.
  #
  # An `Unavailable` passes through unchanged: it came from `storage/1`, which
  # has already classified the one failure it can produce. Anything else is a
  # `Supabase.Error` or something unforeseen, and gets classified here.
  defp classified({:ok, value}, _operation), do: {:ok, value}
  defp classified({:error, %Unavailable{} = error}, _operation), do: {:error, error}
  defp classified({:error, reason}, operation), do: {:error, unavailable(reason, operation)}

  # A bucket handle bound to *this user's* credentials. The access token, not
  # the publishable key: the key would authenticate as `anon`, which holds no
  # grants here at all, and the service key would bypass the policies entirely.
  defp storage(%Session{} = session) do
    case OnePlaylist.Supabase.client_for(session.access_token) do
      {:ok, client} -> {:ok, Supabase.Storage.from(client, @bucket)}
      {:error, :not_configured} -> {:error, unavailable(:not_configured, :client)}
    end
  end

  defp unavailable(:not_configured, _operation) do
    Errata.create(Unavailable,
      reason: :not_configured,
      message: "file storage is not configured on this server"
    )
  end

  defp unavailable(reason, operation) do
    classified = classify(reason)

    # Deliberately not `inspect(reason)`. A `Supabase.Error`'s metadata carries
    # every request header, and headers are where credentials live — the same
    # trap `bin/remote` documents for `%Connection{}`. The classification and
    # the service's own message are what a log line is for.
    Logger.error("Supabase Storage #{operation} failed: #{classified} — #{message_from(reason)}")

    Errata.create(Unavailable, reason: classified, context: %{operation: operation})
  end

  defp message_from(%Supabase.Error{message: message}) when is_binary(message), do: message
  defp message_from(reason), do: inspect(reason, limit: 3)

  # Storage answers **HTTP 400 for everything**, with the status it actually
  # means inside the body: `{"statusCode": "404", "error": "not_found"}`. So
  # `Supabase.Error.code` is `:bad_request` for a missing object, a forbidden
  # one, and a genuine bad request alike, and classifying on it would report
  # every one of them as `:unreachable` — a retryable infrastructure fault, for
  # a file that simply is not there.
  #
  # This is the same shape as the GoTrue error mapping in
  # `OnePlaylist.Accounts`: the SDK reports the transport's status class and the
  # service's real answer is in the payload. See docs/reference/supabase.md.
  defp classify(%Supabase.Error{metadata: metadata}) do
    case status_code(metadata) do
      # 404 and 403 are deliberately the same answer. A file filtered out by the
      # select policy 404s, and one whose insert the with-check refused 403s —
      # telling those apart from "no such file" would confirm that a path names
      # a real object belonging to somebody.
      "404" -> :not_found
      # 403 is deliberately *not* folded into `:not_found`, unlike a read.
      # Reads of another user's file never reach 403 — the select policy filters
      # them and Storage answers 404 — so a 403 only happens on a write, and a
      # write can only address another user's folder if `path_for/3` built the
      # path wrongly. That is this application's bug, and it should be loud
      # rather than disguised as a missing file.
      "403" -> :forbidden
      "401" -> :forbidden
      "413" -> :too_large
      _otherwise -> :unreachable
    end
  end

  defp classify(_reason), do: :unreachable

  # Decoded or raw depending on the response's content type, exactly as GoTrue's
  # errors arrive.
  defp status_code(%{resp_body: %{"statusCode" => code}}), do: code

  defp status_code(%{resp_body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"statusCode" => code}} -> code
      _otherwise -> nil
    end
  end

  defp status_code(_metadata), do: nil
end
