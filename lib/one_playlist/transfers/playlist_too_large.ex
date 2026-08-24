defmodule OnePlaylist.Transfers.PlaylistTooLarge do
  @moduledoc """
  A playlist has more tracks than one transfer is allowed to move.

  **Domain**, not infrastructure: nothing is broken, and the answer is not to
  try again. The playlist really is that big.

  ## This is a safety valve, not a product limit

  The default is deliberately above anything a person is likely to own —
  Spotify's own playlist ceiling is 10,000 tracks, so a limit at that number
  refuses nothing a provider would have held in the first place. It exists to
  stop a runaway rather than to ration the product, and
  `docs/reference/domain.md` treats "moves the library you actually have" as the
  thing this application is for.

  What it guards against is concrete. A provider's track stream is unbounded
  from this side, so a pathological or misreported playlist would pull an
  unbounded number of rows into the worker's memory before the first track was
  even matched — which is why `OnePlaylist.Transfers.Runner` reads one item
  past the limit rather than draining it. And the run that follows is one
  rate-limited provider call per track: at TIDAL's 8 calls a second, ten
  thousand tracks is already twenty minutes of a job that cannot be
  meaningfully watched.

  Raise it with:

      config :one_playlist, OnePlaylist.Transfers, max_tracks: 25_000

  Not retryable. The playlist will be the same size next time.
  """

  use Errata.DomainError,
    default_message: "that playlist has more tracks than a single transfer can move",
    default_reason: :too_many_tracks,
    reasons: [:too_many_tracks],
    code: "PLAYLIST_TOO_LARGE",
    http_status: 422

  def retryable?(_error), do: false
end
