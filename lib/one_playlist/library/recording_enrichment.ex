defmodule OnePlaylist.Library.RecordingEnrichment do
  @moduledoc """
  What enrichment did the last time it was asked about a recording.

  Enrichment's own bookkeeping, kept off the row that says what the music is.
  `docs/reference/domain.md` §6 is the argument and the migration carries the
  detail; the short version is that `library_recordings` is ownerless and shared
  and describes a piece of music, and how *this application's* pipeline got on is
  not that.

  A row exists for every **completed** attempt, whether or not anything was
  learned — `attempted_at` is when MusicBrainz was last asked, not when it last
  answered. No row at all means never asked, which is what `Enrichment.due/1`
  looks for first.

  ## What does not live here

  `Recording.isrc_disputed` stays on the recording, and the distinction is the
  one worth holding on to. An outcome is *this attempt's* answer and is replaced
  by the next one; a disputed ISRC is a durable claim about the code itself,
  read by `OnePlaylist.Library.Identities` when it refuses to anchor an identity
  on it, and it has to outlive an attempt that later succeeds by name.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OnePlaylist.Library.Recording

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "recording_enrichments" do
    belongs_to :recording, Recording

    field :attempted_at, :utc_datetime_usec

    # Why the recording was not identified, and how much there was to work with.
    # The same vocabulary the column on `library_recordings` used, unchanged, so
    # a reader of an old report is not learning new words.
    field :outcome, Ecto.Enum,
      values: [:identified, :no_candidates, :declined, :unnameable, :identifier_disagreed]

    field :candidates, :integer

    # A fingerprint of the engine that decided this outcome, so a decline made
    # under rules that are no longer current can be offered back. See
    # `OnePlaylist.Library.Enrichment.engine/0`.
    field :engine, :string
  end

  @doc """
  The attempt on a recording, or `nil` if it has never been asked about.

  Raises if the association was not loaded, deliberately. A forgotten preload
  reads as "never looked up" for every recording on the screen — a wrong answer
  that looks exactly like a right one, which is the failure mode this project
  keeps finding and keeps refusing to ship. There is no correct silent reading
  of a `NotLoaded`, so this does not invent one.
  """
  @spec of(Recording.t() | nil) :: t() | nil
  def of(nil), do: nil
  def of(%Recording{enrichment: %__MODULE__{} = attempt}), do: attempt
  def of(%Recording{enrichment: nil}), do: nil

  def of(%Recording{enrichment: %Ecto.Association.NotLoaded{}, id: id}) do
    raise ArgumentError, """
    recording #{id} was read without its :enrichment association.

    Preload it — `Repo.preload(recording, :enrichment)`, or `preload: :enrichment`
    in the query — rather than letting a missing attempt and an unread one look
    the same.
    """
  end

  @fields ~w(recording_id attempted_at outcome candidates engine)a
  @required ~w(recording_id attempted_at)a

  @doc """
  Casts an attempt.

  `attempted_at` is required because a row here *is* the record that an attempt
  completed; one without a time is a row that cannot answer the only question
  `due/1` asks of it.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attempt, attrs) do
    attempt
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> foreign_key_constraint(:recording_id)
    |> unique_constraint(:recording_id)
  end
end
