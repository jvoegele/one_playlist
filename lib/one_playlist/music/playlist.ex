defmodule OnePlaylist.Music.Playlist do
  @moduledoc """
  A playlist, described independently of the service it came from.

  Deliberately holds no tracks. A playlist listing is one request; its tracks
  are one request per twenty items, and the test account has a playlist with
  2,030 of them. Keeping the two apart means listing a library does not
  accidentally fetch a hundred thousand tracks.

  `track_count` comes from the provider's own count, so a UI can show the size
  without reading the contents.
  """

  @enforce_keys [:provider, :provider_id]
  defstruct [
    :provider,
    :provider_id,
    :name,
    :description,
    :track_count,
    :duration_seconds,
    :created_at,
    :updated_at,
    :url,
    :owned
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          provider_id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          track_count: non_neg_integer() | nil,
          duration_seconds: non_neg_integer() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          url: String.t() | nil,
          owned: boolean() | nil
        }
end
