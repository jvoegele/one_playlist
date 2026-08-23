defmodule OnePlaylist.Transfers.Candidate do
  @moduledoc """
  One track the matching engine considered, kept so a person can choose it.

  `OnePlaylist.Matching.rank/3` returns every candidate the winning rung had an
  opinion about, best first, and its own documentation names this screen as the
  reason it is public. What it returns is `%Match{}` structs holding whole
  `%Track{}`s; this is the flattened, storable form of one of them.

  ## What is kept, and why each field is here

  Two jobs, and every field serves one of them.

  **Showing the candidate to a person**: title, artist, album, duration. Enough
  to tell three recordings of the same song apart, which is the entire question
  being asked.

  **Explaining why the engine refused it**: `score`, and the three conflicts.
  A rejected candidate with no reason attached is worse than no candidate at
  all — it invites the reader to assume the engine is simply broken, when in
  most cases it refused for a reason they would agree with.

  `provider_id` is what an override is actually made of. The rest is display.

  ## Why not an `embeds_many`

  `OnePlaylist.Transfers.record_run/3` writes the report with `insert_all`,
  which does not cast embeds. A plain `{:array, :map}` field dumps through the
  schema's field type and needs no special handling there, at the cost of doing
  the conversion here explicitly.

  Nothing queries into these — they are read with the row that owns them — so
  the usual reason to prefer a real embedded schema does not apply.
  """

  use Bond

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track

  @type t :: %__MODULE__{
          provider_id: String.t(),
          title: String.t() | nil,
          artist: String.t() | nil,
          album: String.t() | nil,
          duration_seconds: non_neg_integer() | nil,
          isrc: String.t() | nil,
          score: float(),
          confidence: String.t(),
          strategy: String.t(),
          duration_delta_seconds: integer() | nil,
          version_conflict: boolean(),
          duration_conflict: boolean(),
          editorial_conflict: boolean()
        }

  @enforce_keys [:provider_id, :score, :confidence, :strategy]
  defstruct [
    :provider_id,
    :title,
    :artist,
    :album,
    :duration_seconds,
    :isrc,
    :score,
    :confidence,
    :strategy,
    :duration_delta_seconds,
    version_conflict: false,
    duration_conflict: false,
    editorial_conflict: false
  ]

  @doc """
  Flattens one ranked `%Match{}` into its storable form.
  """
  # `provider_id` is the only field an override cannot be made without: it is
  # what gets written to the destination playlist. A candidate list carrying a
  # blank one renders perfectly and produces a correction that adds nothing.
  @post identifiable: result.provider_id not in [nil, ""]
  @spec from_match(Match.t()) :: t()
  def from_match(%Match{} = match) do
    signals = Signals.compare(match.source, match.track)

    %__MODULE__{
      provider_id: match.track.provider_id,
      title: match.track.title,
      artist: List.first(match.track.artists),
      album: match.track.album,
      duration_seconds: match.track.duration_seconds,
      isrc: match.track.isrc,
      score: match.score,
      confidence: to_string(match.confidence),
      strategy: to_string(match.strategy),
      duration_delta_seconds: duration_delta(match.source, match.track),
      # `discriminating_conflict` is the version veto — the rule that stops a
      # karaoke or live recording matching the original. Renamed here because
      # "discriminating" describes the mechanism to a reader of the matching
      # engine, and this value is read by someone looking at a table of songs.
      version_conflict: signals.discriminating_conflict,
      duration_conflict: signals.duration_conflict,
      editorial_conflict: signals.editorial_conflict
    }
  end

  @doc """
  The top `limit` candidates, in the form the report column stores.
  """
  # Conservation, in the shape `docs/reference/contracts.md` calls the closest
  # thing here to Bond's own Ledger example: a mapper reading from the wrong
  # collection, or a `take` that silently drops the *best* candidate rather than
  # the worst, produces a plausible list of the wrong songs.
  @post never_more_than_asked_for: length(result) <= limit
  @post none_invented: length(result) <= length(ranked)
  @post best_first: descending_scores?(result)
  @spec top([Match.t()], pos_integer()) :: [map()]
  def top(ranked, limit) when is_list(ranked) and is_integer(limit) and limit > 0 do
    ranked
    |> Enum.take(limit)
    |> Enum.map(&(&1 |> from_match() |> to_map()))
  end

  @doc """
  Reads one back out of the column.

  Tolerant by design: these rows were written by an earlier version of this
  module and will outlive it. A candidate missing a field it did not have when
  it was stored should render without it, not crash the report.
  """
  @spec from_map(map()) :: t()
  def from_map(%{} = stored) do
    %__MODULE__{
      provider_id: stored["provider_id"],
      title: stored["title"],
      artist: stored["artist"],
      album: stored["album"],
      duration_seconds: stored["duration_seconds"],
      isrc: stored["isrc"],
      score: stored["score"],
      confidence: stored["confidence"],
      strategy: stored["strategy"],
      duration_delta_seconds: stored["duration_delta_seconds"],
      version_conflict: stored["version_conflict"] || false,
      duration_conflict: stored["duration_conflict"] || false,
      editorial_conflict: stored["editorial_conflict"] || false
    }
  end

  @doc "The stored form: string keys, JSON-safe values."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = candidate) do
    candidate |> Map.from_struct() |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp duration_delta(%Track{duration_seconds: source}, %Track{duration_seconds: candidate})
       when is_integer(source) and is_integer(candidate),
       do: candidate - source

  defp duration_delta(_source, _candidate), do: nil

  defp descending_scores?(candidates) do
    scores = Enum.map(candidates, & &1["score"])

    scores == Enum.sort(scores, :desc)
  end
end
