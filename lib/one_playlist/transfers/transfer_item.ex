defmodule OnePlaylist.Transfers.TransferItem do
  @moduledoc """
  What happened to one track, and why.

  One row per track of the source playlist — which is the point. "Never
  silently drop a track" is a claim about the whole application, and this table
  is where it becomes checkable: a source track with no row here is a bug the
  database can be asked about, rather than an absence nobody notices.

  Three outcomes, and the distinction between the last two is the one that
  makes a report worth reading:

  | Outcome | Means |
  | --- | --- |
  | `:matched` | Resolved and written to the destination. |
  | `:already_present` | Resolved, and the destination already had it. |
  | `:unmatched` | Not resolved confidently. `reason` says which kind. |

  `:already_present` is what idempotency looks like from the report's side. A
  re-run of a completed transfer turns every `:matched` into
  `:already_present` and adds nothing — and a user looking at the report can
  see that is what happened, rather than wondering why the second run "did
  nothing".
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Track

  @outcomes ~w(matched already_present unmatched)a

  @type outcome :: :matched | :already_present | :unmatched

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          transfer_id: Ecto.UUID.t() | nil,
          position: non_neg_integer() | nil,
          source_track_id: String.t() | nil,
          outcome: outcome() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfer_items" do
    field :transfer_id, :binary_id
    field :user_id, Ecto.UUID

    field :position, :integer

    field :source_track_id, :string
    field :source_title, :string
    field :source_artist, :string

    field :outcome, Ecto.Enum, values: @outcomes
    field :destination_track_id, :string
    field :confidence, :string
    field :score, :float
    field :strategy, :string
    field :reason, :string
    field :candidates_considered, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The outcomes an item can record."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  The row for a track that resolved.

  `added?` decides between `:matched` and `:already_present`; everything else
  is copied off the `OnePlaylist.Matching.Match` so the report can explain the
  decision without re-running it.
  """
  @spec matched(map(), non_neg_integer(), Match.t(), boolean()) :: map()
  def matched(base, position, %Match{} = match, added?) do
    base
    |> common(position, match.source)
    |> Map.merge(%{
      outcome: if(added?, do: :matched, else: :already_present),
      destination_track_id: match.track.provider_id,
      confidence: to_string(match.confidence),
      score: match.score,
      strategy: to_string(match.strategy)
    })
  end

  @doc """
  The row for a track that did not resolve.

  Carries the reason and how many candidates were considered, because
  "nothing was found" and "four were found and none was good enough" are
  different problems with different fixes — and only the second is worth
  offering the user a manual choice for.
  """
  @spec unmatched(map(), non_neg_integer(), Track.t(), Exception.t()) :: map()
  def unmatched(base, position, %Track{} = source, error) do
    context = Errata.context(error)

    base
    |> common(position, source)
    |> Map.merge(%{
      outcome: :unmatched,
      reason: to_string(Errata.reason(error)),
      score: context[:best_score],
      confidence: context[:best_confidence] && to_string(context[:best_confidence]),
      candidates_considered: context[:candidates_considered]
    })
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :transfer_id,
      :user_id,
      :position,
      :source_track_id,
      :source_title,
      :source_artist,
      :outcome,
      :destination_track_id,
      :confidence,
      :score,
      :strategy,
      :reason,
      :candidates_considered
    ])
    |> validate_required([:transfer_id, :user_id, :position, :source_track_id, :outcome])
  end

  defp common(base, position, %Track{} = source) do
    Map.merge(base, %{
      position: position,
      source_track_id: source.provider_id,
      source_title: source.title,
      # The first credited artist only. The report is a list a person scans;
      # the full credit is on the source track if anyone needs it.
      source_artist: List.first(source.artists || [])
    })
  end
end
