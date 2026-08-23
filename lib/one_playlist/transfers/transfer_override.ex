defmodule OnePlaylist.Transfers.TransferOverride do
  @moduledoc """
  A track the user matched by hand, after the engine got it wrong.

  Read by `OnePlaylist.Transfers.Runner` **before** the matching ladder runs,
  which is the whole design. See the migration that creates this table for why
  a correction cannot live on the report row it corrects.

  ## What it holds, and what it deliberately does not

  The destination track's id, which is the correction itself, plus its title and
  artist so the report can be drawn without asking the provider again.

  It does **not** hold a confidence or a score. Those describe how strongly an
  algorithm believes something, and this row exists precisely because a person
  overruled the algorithm. `OnePlaylist.Matching.Match.chosen_by_hand/2` turns
  one of these into the shape the pipeline expects, and it is explicit about
  reporting no score at all rather than a fabricated `1.0`.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Music.Track

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transfer_overrides" do
    field :transfer_id, :binary_id
    field :user_id, Ecto.UUID

    field :position, :integer

    field :destination_track_id, :string
    field :destination_title, :string
    field :destination_artist, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          transfer_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          position: non_neg_integer() | nil,
          destination_track_id: String.t() | nil,
          destination_title: String.t() | nil,
          destination_artist: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  # An override with a blank destination id is a correction that corrects
  # nothing: the runner would treat it as a match, report the track as added,
  # and write an empty id to the destination playlist. The report would look
  # like a success.
  @invariant names_a_destination_track:
               subject.destination_track_id == nil or subject.destination_track_id != ""

  @required ~w(transfer_id user_id position destination_track_id)a
  @optional ~w(destination_title destination_artist)a

  @doc """
  Builds a correction.

  `position` is the track's place in the source playlist, which is what the
  report is keyed on and therefore what the runner looks up.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = override, attrs) do
    override
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    # Distinct from the invariant above, which is about the value; this is about
    # what a *caller* may submit. An empty string reaches here from a form.
    |> validate_length(:destination_track_id, min: 1)
    |> unique_constraint([:transfer_id, :position])
  end

  @doc """
  The destination track this names, as far as it is known.

  Enough for the pipeline to write it and for the report to show it. There is no
  ISRC, duration or album here and there does not need to be: the track is
  identified by the id a person already chose from a candidate list, and every
  field the matching engine would have compared has been overruled.

  `provider` comes from the transfer rather than from a column here. It is not
  free-floating information — every adapter's `search_tracks/3` promises that
  every track it returns belongs to *its own* provider, and a track carrying the
  wrong one would be written to the wrong service's playlist.
  """
  # No connection to build and none to check.
  @bond_warn_skipped_invariants false
  @spec as_track(t(), atom()) :: Track.t()
  def as_track(%__MODULE__{} = override, provider) when is_atom(provider) do
    %Track{
      provider: provider,
      provider_id: override.destination_track_id,
      title: override.destination_title,
      artists: List.wrap(override.destination_artist)
    }
  end
end
