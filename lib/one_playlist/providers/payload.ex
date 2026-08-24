defmodule OnePlaylist.Providers.Payload do
  @moduledoc """
  Turning untrusted values out of a provider's JSON into domain values.

  Every provider mapper needs the same handful of coercions —
  `OnePlaylist.Providers.Tidal.Mapper` and
  `OnePlaylist.Providers.Subsonic.Mapper` want identical answers about a blank
  string, a timestamp and a count. One rule per concept, in one place, with
  nothing to keep in step.

  ## Why the boundary deserves a module of its own

  `docs/reference/contracts.md` says of a parsing boundary: *assert what you
  emit, never what you received*. A provider sending nonsense is not a
  programming error, so nothing here rejects an input — every function takes
  `term()` and answers `nil` for anything it cannot use.

  What each one *does* promise is the shape of its output, and stating that once
  here means every mapper inherits it. That is the point: these are the
  functions that stand between a stranger's JSON and the values the matching
  engine compares, and a wrong answer from any of them is silent by
  construction.

  ## Naming

  Named for what they produce rather than for the check they perform —
  `count/1`, not `non_negative_integer/1`. A reader of `Mapper.playlist/1`
  needs to know what the value *is*, not which guard it survived.
  """

  use Bond

  @doc """
  A non-blank string, or `nil`.

  The empty string is the dangerous value this exists to remove, and `isrc` is
  where it does real damage: an ISRC is compared for **exact equality** by the
  first and most trusted rung of the matching ladder, so two tracks that both
  carry `""` match each other perfectly. That is a false positive — the
  direction that puts the wrong recording in somebody's playlist — arriving
  from two providers that simply left a field empty.

      iex> alias OnePlaylist.Providers.Payload
      iex> {Payload.text("Moby Grape"), Payload.text(""), Payload.text(nil), Payload.text(42)}
      {"Moby Grape", nil, nil, nil}
  """
  @post never_blank: is_nil(result) or (is_binary(result) and result != "")
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) and value != "", do: value
  def text(_value), do: nil

  @doc """
  A count of things — zero or more — or `nil`.

  `nil` rather than `0` for an unusable value, because "the provider did not say"
  and "the provider said none" are different facts and a UI should be able to
  tell them apart.

      iex> alias OnePlaylist.Providers.Payload
      iex> {Payload.count(14), Payload.count(0), Payload.count(-3), Payload.count("14")}
      {14, 0, nil, nil}
  """
  # The bug on record: TIDAL's `numberOfItems` passed straight through, so a
  # negative reaches `Playlist.track_count`, where it is counted against in
  # transfer reports. A report reading "-3 tracks transferred" is worse than one
  # that fails.
  @post never_negative: is_nil(result) or (is_integer(result) and result >= 0)
  @spec count(term()) :: non_neg_integer() | nil
  def count(value) when is_integer(value) and value >= 0, do: value
  def count(_value), do: nil

  @doc """
  A position within a release — first is 1 — or `nil`.

  Zero is not a position, which is what separates this from `count/1`. Rung 2 of
  the matching ladder pairs a barcode with a position, so a zero or negative
  would be compared against real positions and could pair two unrelated tracks
  off a shared release.

      iex> alias OnePlaylist.Providers.Payload
      iex> {Payload.position(3), Payload.position(0), Payload.position(-1)}
      {3, nil, nil}
  """
  @post always_positive: is_nil(result) or (is_integer(result) and result > 0)
  @spec position(term()) :: pos_integer() | nil
  def position(value) when is_integer(value) and value > 0, do: value
  def position(_value), do: nil

  @doc """
  An ISO 8601 timestamp, or `nil`.

  Unparseable input is `nil` rather than an exception: a missing timestamp costs
  a column in a listing, while raising costs the whole library read.

      iex> alias OnePlaylist.Providers.Payload
      iex> Payload.timestamp("2026-08-22T12:00:00Z")
      ~U[2026-08-22 12:00:00Z]
      iex> {Payload.timestamp("not a date"), Payload.timestamp(nil)}
      {nil, nil}
  """
  @post is_a_timestamp: is_nil(result) or is_struct(result, DateTime)
  @spec timestamp(term()) :: DateTime.t() | nil
  def timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  def timestamp(_value), do: nil

  @doc """
  Parses an ISO 8601 duration into whole seconds.

  Providers report duration in incompatible ways — TIDAL uses ISO 8601
  (`"PT4M6S"`), others use milliseconds — so normalizing here keeps the
  difference out of the matching code.

  Returns `nil` rather than raising on anything unparseable: a missing duration
  costs one matching signal, while an exception costs the whole transfer.
  """
  # A recording cannot be of negative length, so a negative result is not a
  # shorter duration — it is a value that must not reach the matching engine,
  # where it would be compared against real durations and score as a near miss.
  #
  # This is not hypothetical: ISO 8601 admits negative components, and
  # `Duration.from_iso8601/1` accepts them. Measured before this contract
  # existed: `"PT-5S"` parsed to `-5`, `"P-1DT-1S"` to `-86_401`.
  @post non_negative: is_nil(result) or result >= 0
  @spec duration(String.t() | nil) :: non_neg_integer() | nil
  def duration(value)

  def duration(nil), do: nil

  def duration(value) when is_binary(value) do
    with {:ok, duration} <- Duration.from_iso8601(value),
         seconds when seconds >= 0 <- to_seconds(duration) do
      seconds
    else
      _negative_or_unparseable -> nil
    end
  end

  def duration(_value), do: nil

  # Deliberately ignores :year and :month. They cannot appear in a track length,
  # and treating them as fixed spans would be wrong if they ever did.
  defp to_seconds(%Duration{} = d) do
    d.week * 604_800 + d.day * 86_400 + d.hour * 3600 + d.minute * 60 + d.second
  end
end
