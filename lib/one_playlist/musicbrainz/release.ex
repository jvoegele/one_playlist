defmodule OnePlaylist.MusicBrainz.Release do
  @moduledoc """
  One MusicBrainz release, with its track list, cached because releases barely
  change.

  The row behind release-first search. Every strategy in the matching ladder
  searches by **track title** and treats the album as corroboration, which for a
  live bootleg is backwards: *Live: 05-03-03 - State College, Pennsylvania* is
  enormously more distinctive than *[improvisation]*, and a title that is not a
  name carries no signal at all.

  See the migration for why nothing here expires, and
  `docs/reference/domain.md` §3 for the case that prompted it.

  `tracks` is a list of maps rather than a schema of its own, and deliberately:
  nothing joins to it, it is read whole and compared in Elixir, and normalizing
  a cache invites treating it as a source of truth. `OnePlaylist.Library.Recording`
  is where a recording becomes a fact about this application; this is a copy of
  somebody else's catalogue.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @type track :: %{
          optional(String.t()) => term()
        }

  @primary_key {:mbid, Ecto.UUID, autogenerate: false}
  schema "musicbrainz_releases" do
    field :title, :string
    field :artist_credit, :string
    field :barcode, :string
    field :date, :string

    field :release_group_mbid, Ecto.UUID
    field :release_group_title, :string
    field :primary_type, :string
    field :secondary_types, {:array, :string}, default: []

    # `[%{"position" => 10, "title" => "[improvisation]",
    #     "recording_mbid" => "78ae…", "length_ms" => 188_000}, …]`
    field :tracks, {:array, :map}, default: []

    field :looked_up_at, :utc_datetime_usec
  end

  @doc """
  Whether this release is live all the way through.

  `secondary_types` reads `["Live"]` for an official bootleg or a live album,
  which is what `OnePlaylist.Music.Track`'s `live_release?` means and why the
  version veto does not fire against one — see
  `OnePlaylist.Matching.Signals`.
  """
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{secondary_types: types}), do: "Live" in List.wrap(types)

  @doc """
  Every title this release lists, in track order.

  The thing release-first search compares against. A recording's own title and
  its title *on a release* are different fields and disagree more often than one
  would guess — this is the second one.
  """
  @spec track_titles(t()) :: [String.t()]
  def track_titles(%__MODULE__{tracks: tracks}) do
    tracks |> List.wrap() |> Enum.map(& &1["title"]) |> Enum.reject(&is_nil/1)
  end
end
