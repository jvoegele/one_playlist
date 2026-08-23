defmodule OnePlaylist.Providers.Payload do
  @moduledoc """
  Turning untrusted values out of a provider's JSON into domain values.

  Every provider mapper needs the same handful of coercions, and each had
  written its own. `blank_to_nil/1` was byte-identical in
  `OnePlaylist.Providers.Tidal.Mapper` and
  `OnePlaylist.Providers.Subsonic.Mapper`; so was `parse_datetime/1`; and
  `non_negative_count/1` and `non_negative_integer/1` were the same two lines
  under two names. One rule per concept, written twice, with nothing keeping the
  copies in step.

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
  `count/1`, not `non_negative_integer/1`. The old names described the guard;
  these describe the value, which is what a reader of `Mapper.playlist/1` needs
  to know.
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
  # The bug on record: TIDAL's `numberOfItems` was passed straight through, and a
  # negative reached `Playlist.track_count`, where it is counted against in
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
end
