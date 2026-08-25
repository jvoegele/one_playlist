defmodule OnePlaylist.Errors do
  @moduledoc """
  How this application renders a failure it is about to write down.

  One function so far, and it exists because `inspect/1` is the wrong tool for
  the errors this codebase actually produces.

  ## Why not `inspect/1`

  Every outbound call goes through `ExternalService`, which reports a failure as
  a `RetriesExhausted` **wrapping** whatever went wrong. Inspecting one of those
  prints the struct: the message that says only that retrying did not help, the
  whole `Errata.Env` — module, function, file, line — and the captured
  stacktrace, as one unbroken line. Measured on a real log entry from this
  session, that is upwards of two thousand characters in which the actual cause
  appears once, in the middle, as a nested struct.

  `Errata.format_chain/1` renders the same value as the head message and a
  `Caused by:` line per level, recursing through wrapped Errata errors and
  formatting a foreign original with `Exception.format/3` — so the thing that
  went wrong is on its own line, in words, at the bottom.

  ## Why a wrapper rather than calling it directly

  `format_chain/1` raises `ArgumentError` on a non-Errata value, and these call
  sites are exactly where foreign shapes arrive — a `Nebulex` error, a
  `Postgrex` error, a bare atom from a library that does not use Errata. Raising
  inside a `Logger.warning/1` would replace a logged failure with a crash, in
  the one place that exists to record failures quietly.

  That is the guard `errata`'s own usage rules prescribe, and this is the second
  place in this codebase that needs it — see `OnePlaylist.Providers.root_error/1`
  for the first. Written once here rather than at each `Logger` call.
  """

  import Errata, only: [is_error: 1]

  @doc """
  A failure, rendered for a log entry.

  An Errata error becomes its full cause chain; anything else is inspected,
  which is what the call sites did before and remains right for a value with no
  chain to show.

      iex> alias OnePlaylist.Errors
      iex> Errors.describe(:enoent)
      ":enoent"

      iex> alias OnePlaylist.Errors
      iex> error = Errata.create(OnePlaylist.Matching.TrackNotMatched, reason: :no_candidates)
      iex> Errors.describe(error) =~ "TrackNotMatched"
      true
  """
  @spec describe(term()) :: String.t()
  def describe(error) when is_error(error), do: Errata.format_chain(error)
  def describe(other), do: inspect(other)
end
