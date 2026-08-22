defmodule OnePlaylist.Catalogue.ReleaseLookup do
  @moduledoc """
  One remembered answer to "which album is this barcode, at this provider?".

  `provider_album_id` being `nil` is meaningful and is not the same as the row
  being absent:

  | | Means |
  | --- | --- |
  | no row | never asked |
  | row, `provider_album_id` set | asked; this is the album |
  | row, `provider_album_id` `nil` | asked; this provider does not carry it |

  The third is the one worth having a row for. Without it, every track on a
  release the provider lacks re-asks and re-learns the same nothing, which is
  the case that costs the most and is easiest to miss.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{
          provider: String.t(),
          barcode: String.t(),
          provider_album_id: String.t() | nil,
          looked_up_at: DateTime.t()
        }

  schema "catalogue_release_lookups" do
    field :provider, :string, primary_key: true
    field :barcode, :string, primary_key: true
    field :provider_album_id, :string
    field :looked_up_at, :utc_datetime_usec
  end
end
