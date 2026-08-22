defmodule OnePlaylist.Vault do
  @moduledoc """
  Application-side encryption for values that must never sit in Postgres as
  plaintext — principally the OAuth access and refresh tokens in
  `OnePlaylist.Providers.Connection`.

  ## Why not Supabase Vault

  Supabase Vault would be the platform-native choice, and it is a good one for
  secrets the *database* needs to use — a credential read by a `pg_cron` job or
  an Edge Function. It is the wrong choice here, for one reason: with Vault the
  Postgres server can decrypt, which means on a hosted project the database
  operator can read every user's third-party tokens. A provider refresh token
  grants standing access to someone's music library, so it should be readable
  only by this application.

  Encrypting in the application keeps ciphertext in the database, in backups,
  in dumps, and in anything replicated out of it. Supabase Vault stays on the
  table for our *own* credentials, where the database is the consumer.

  ## Keys

  The key is supplied as base64 in `ONE_PLAYLIST_VAULT_KEY` and read at
  runtime. `dev` and `test` fall back to a fixed, well-known key held in config
  so a checkout works without setup — that key is worthless and must never
  appear in `prod`.

  Keys are a list so that rotation is possible: add the new key at the head with
  a fresh label, leave the old one in place to decrypt existing rows, then
  re-encrypt and drop it. Cloak tags each ciphertext with the label that wrote
  it, so a mixed table decrypts correctly throughout.
  """

  use Cloak.Vault, otp_app: :one_playlist

  @impl GenServer
  def init(config) do
    {:ok, Keyword.put(config, :ciphers, default: cipher())}
  end

  defp cipher do
    {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key(), iv_length: 12}
  end

  defp key do
    case Application.get_env(:one_playlist, __MODULE__)[:key] do
      nil ->
        raise """
        No encryption key configured for #{inspect(__MODULE__)}.

        Set ONE_PLAYLIST_VAULT_KEY to a base64-encoded 32-byte key. Generate one with:

            mix one_playlist.gen.vault_key
        """

      key when is_binary(key) ->
        decode_key!(key)
    end
  end

  defp decode_key!(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == 32 ->
        decoded

      {:ok, decoded} ->
        raise ArgumentError,
              "ONE_PLAYLIST_VAULT_KEY must decode to 32 bytes, got #{byte_size(decoded)}"

      :error ->
        raise ArgumentError, "ONE_PLAYLIST_VAULT_KEY must be valid base64"
    end
  end
end
