defmodule OnePlaylist do
  @moduledoc """
  Moves a playlist from one music service to another, and says what happened
  to every track.

  This module is a namespace and holds no code. What follows is where to start
  reading; the sidebar groups the rest along the same lines.

  ## The core

  `OnePlaylist.Matching` is the technical core, and everything else is plumbing
  in service of it: given a track on one service, find the same recording on
  another. It works as a **ladder** of strategies, tried in order of how much
  their kind of evidence is worth, and it never silently drops a track — every
  miss is a typed error carrying what was tried and how close it came.

  `OnePlaylist.Music.Track` is the currency it deals in: a recording described
  independently of the service it came from.

  ## Getting tracks in and out

  `OnePlaylist.Providers` owns a user's authorization at each service, and
  `OnePlaylist.Providers.Adapter` is the behaviour every service implements —
  TIDAL and any Subsonic-compatible server today. `OnePlaylist.Formats` is the
  counterpart for playlists that are files rather than services, which is a
  deliberately different shape and not another provider.

  ## Running a transfer

  `OnePlaylist.Transfers` queues one and `OnePlaylist.Transfers.Runner`
  executes it: snapshot the destination, resolve every track, write the
  difference, then re-read to confirm the writes landed. Re-running is a diff
  rather than a flag, so it is safe by construction.

  ## Reference

  `docs/reference/domain.md` covers the matching ladder and each platform's
  real API limits; `docs/reference/contracts.md` is the house style for the
  `Bond` contracts that appear throughout.
  """
end
