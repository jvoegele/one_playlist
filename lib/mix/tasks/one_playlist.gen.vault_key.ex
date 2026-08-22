defmodule Mix.Tasks.OnePlaylist.Gen.VaultKey do
  @shortdoc "Generates a base64 encryption key for OnePlaylist.Vault"

  @moduledoc """
  Generates a random 32-byte key, base64 encoded, for `OnePlaylist.Vault`.

      $ mix one_playlist.gen.vault_key

  Set the result as `ONE_PLAYLIST_VAULT_KEY` in the target environment. It
  encrypts users' third-party OAuth tokens, so treat it like a database
  password: never commit it, and losing it means every stored token has to be
  re-authorized by its user.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Mix.shell().info()
  end
end
