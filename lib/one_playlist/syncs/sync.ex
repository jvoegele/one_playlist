defmodule OnePlaylist.Syncs.Sync do
  @moduledoc """
  A standing instruction to keep one playlist mirrored into another.

  A `OnePlaylist.Transfers.Transfer` is a thing that happened once and carries
  what happened — counters, a report, a status. A sync carries none of that: it
  is the *instruction*, and each run produces a transfer of its own. That split
  is what lets a sync's history be the ordinary transfers list rather than a
  second reporting surface built beside it.

  ## Add-only, for now

  A run adds what the source has gained and never removes. That is exactly what
  running a transfer twice already does, so the first cut of this feature is the
  schedule and nothing else — and it is the safe default, because a bug adds a
  duplicate rather than deleting somebody's music. Replace mode is the second
  piece, and `c:OnePlaylist.Providers.Adapter.remove_tracks/4` is already in
  place for it.

  ## The destination is pinned after the first run

  `destination_playlist_id` starts `nil` and is filled by the first run that
  creates the playlist. Every run after that writes into the same one; without
  the pin, a weekly sync leaves fifty-two playlists behind. See the migration.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Providers.Connection

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  # An hour is the floor and it is a quota decision rather than a technical one.
  # TIDAL rate-limits reads, a source playlist is a request per twenty tracks,
  # and a sync that ran every minute would spend a user's whole budget
  # discovering nothing had changed.
  @minimum_interval_minutes 60

  # A fortnight. Beyond this the feature is not really "keep these in step" any
  # more, and a schedule nobody remembers setting is a schedule that surprises
  # them.
  @maximum_interval_minutes 60 * 24 * 14

  schema "syncs" do
    field :user_id, Ecto.UUID

    field :source_provider, Ecto.Enum, values: Connection.providers() ++ [:file]
    field :source_playlist_id, :string
    field :source_playlist_name, :string

    field :destination_provider, Ecto.Enum, values: Connection.providers()
    field :destination_playlist_id, :string
    field :destination_playlist_name, :string

    field :interval_minutes, :integer
    field :enabled, :boolean, default: true

    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec
    field :last_transfer_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The narrowest and widest cadence a sync may be given, in minutes.

  Public because the form offering the choices and the changeset refusing them
  must agree, and a bound written out twice is a bound that drifts.
  """
  @spec interval_bounds() :: {pos_integer(), pos_integer()}
  def interval_bounds, do: {@minimum_interval_minutes, @maximum_interval_minutes}

  @doc """
  A new sync from what the user chose.

  `destination_playlist_id` is deliberately **not** castable here: it is the
  first run's to write, and a caller supplying one would point a schedule at a
  playlist nobody checked they own.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = sync, attrs) do
    sync
    |> cast(attrs, [
      :user_id,
      :source_provider,
      :source_playlist_id,
      :source_playlist_name,
      :destination_provider,
      :destination_playlist_name,
      :interval_minutes,
      :enabled,
      :next_run_at
    ])
    |> validate_required([
      :user_id,
      :source_provider,
      :source_playlist_id,
      :destination_provider,
      :interval_minutes
    ])
    |> validate_number(:interval_minutes,
      greater_than_or_equal_to: @minimum_interval_minutes,
      less_than_or_equal_to: @maximum_interval_minutes
    )
    # Named explicitly: Postgres truncates an identifier at 63 characters, and
    # the name Ecto derives from these four columns is longer than that — so the
    # inferred name never matches and the violation raises instead of becoming a
    # changeset error.
    |> unique_constraint(
      [:user_id, :source_provider, :source_playlist_id, :destination_provider],
      name: "syncs_user_id_source_provider_source_playlist_id_destination_pr",
      message: "is already being synced to that service"
    )
  end

  @doc false
  @spec run_changeset(t(), map()) :: Ecto.Changeset.t()
  def run_changeset(%__MODULE__{} = sync, attrs) do
    cast(sync, attrs, [
      :destination_playlist_id,
      :destination_playlist_name,
      :last_run_at,
      :next_run_at,
      :last_transfer_id,
      :enabled
    ])
  end

  @doc """
  Whether this sync is ready to run at `now`.

  Both halves matter and neither implies the other: a disabled sync keeps its
  `next_run_at` so that re-enabling it does not lose its place, and a sync that
  has never been scheduled has none at all.
  """
  @spec due?(t(), DateTime.t()) :: boolean()
  def due?(%__MODULE__{enabled: false}, _now), do: false
  def due?(%__MODULE__{next_run_at: nil}, _now), do: false

  def due?(%__MODULE__{next_run_at: at}, now), do: not DateTime.after?(at, now)

  @doc """
  When a sync that has just run should run again.

  From **now** rather than from the schedule it missed. A sync whose provider was
  down for a day would otherwise come back and fire every missed slot in
  sequence, spending a day's quota to arrive at the same answer once.
  """
  # A precondition rather than the postcondition this first carried, and the
  # difference is who is at fault. `@post schedules_forward: DateTime.after?(...)`
  # looked like the law worth stating — but the body clamped the interval with
  # `max(minutes, @minimum_interval_minutes)`, which made the postcondition
  # unfalsifiable: no input could produce a time that was not after `now`. The
  # coverage table said so on the first run.
  #
  # The clamp was the real problem. Silently rewriting -60 to 60 is this
  # function absorbing a caller's mistake and answering a schedule nobody asked
  # for. The bound belongs to the caller, so it is stated as a demand on them.
  #
  # The changeset bounds what can be *stored*; this bounds what can be computed
  # from a struct built any other way, a fixture included.
  @pre interval_is_a_cadence: is_integer(minutes) and minutes >= @minimum_interval_minutes
  @spec next_run_after(t(), DateTime.t()) :: DateTime.t()
  def next_run_after(%__MODULE__{interval_minutes: minutes}, now) do
    DateTime.add(now, minutes * 60, :second)
  end
end
