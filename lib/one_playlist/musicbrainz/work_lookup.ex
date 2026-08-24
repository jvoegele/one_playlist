defmodule OnePlaylist.MusicBrainz.WorkLookup do
  @moduledoc """
  One remembered answer to "what catalogue number does this work go by?".

  `catalogue_titles` being `nil` is meaningful and is not the same as the row
  being absent:

  | | Means |
  | --- | --- |
  | no row | never asked |
  | row, titles set | asked; these carry the numbers |
  | row, titles `nil` | asked; MusicBrainz had nothing |

  The third is the row worth having. A playlist is mostly not classical, and
  every pop title reaching this lookup would otherwise re-ask a
  one-request-per-second service to be told nothing again.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{
          query: String.t(),
          catalogue_titles: [String.t()] | nil,
          looked_up_at: DateTime.t()
        }

  schema "musicbrainz_work_lookups" do
    field :query, :string, primary_key: true
    field :catalogue_titles, {:array, :string}
    field :looked_up_at, :utc_datetime_usec
  end
end
