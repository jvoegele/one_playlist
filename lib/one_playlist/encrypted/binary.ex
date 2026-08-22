defmodule OnePlaylist.Encrypted.Binary do
  @moduledoc """
  An `Ecto.Type` for a string that is encrypted at rest by `OnePlaylist.Vault`.

  The column is `:binary`; the struct field is a plain string. Encryption and
  decryption happen in the application, so the value only ever reaches Postgres
  as ciphertext.
  """

  use Cloak.Ecto.Binary, vault: OnePlaylist.Vault
end
