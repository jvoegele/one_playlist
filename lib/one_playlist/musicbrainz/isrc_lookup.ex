defmodule OnePlaylist.MusicBrainz.IsrcLookup do
  @moduledoc """
  One remembered answer to "what else is this recording called?".

  `recording_mbid` being `nil` is meaningful and is not the same as the row
  being absent:

  | | Means |
  | --- | --- |
  | no row | never asked |
  | row, `recording_mbid` set | asked; these are its ISRCs |
  | row, `recording_mbid` `nil` | asked; MusicBrainz does not know this ISRC |

  The third is the one worth a row. Without it a playlist full of bootlegs
  re-asks a volunteer-run service, at one request a second, to be told nothing
  it was not told last time. It is also the row the nightly prune expires,
  because MusicBrainz is edited continuously and today's gap is next month's
  entry.
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{
          isrc: String.t(),
          recording_mbid: Ecto.UUID.t() | nil,
          isrcs: [String.t()] | nil,
          looked_up_at: DateTime.t()
        }

  schema "musicbrainz_isrc_lookups" do
    field :isrc, :string, primary_key: true
    field :recording_mbid, Ecto.UUID
    field :isrcs, {:array, :string}
    field :looked_up_at, :utc_datetime_usec
  end
end
