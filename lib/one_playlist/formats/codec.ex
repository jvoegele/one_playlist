defmodule OnePlaylist.Formats.Codec do
  @moduledoc """
  Reading and writing one playlist file format.

  Implementations are **pure functions on binaries**. No HTTP, no credentials,
  no clock, no rate limit — which is what separates this behaviour from
  `OnePlaylist.Providers.Adapter` and is why it is a behaviour of its own rather
  than another provider. A file is not a service, and pretending otherwise would
  give every codec a `search_tracks/3` with nothing to search.

  ## Path-based and metadata-based formats are not interchangeable

  `c:kind/0` exists because the difference decides what a format can be used
  *for*, and it is not obvious until it bites:

    * `:metadata_based` — CSV, JSON, XSPF. A track is described by title,
      artist, album, identifiers. Such a file crosses service boundaries,
      because those fields mean the same thing to TIDAL as to Navidrome.
    * `:path_based` — M3U, PLS. A track is a **filesystem path**. Such a file
      only means anything on a machine that has those files, so it round-trips
      a local library and cannot be exported from a streaming service at all —
      there is no path to write.

  Offering "export to M3U" from a TIDAL playlist would produce a file of paths
  that exist nowhere. The kind is what lets the UI decline that rather than
  produce it.

  ## Parsing is a filter, in Meyer's sense

  `c:parse/2` faces a person's uploaded file, so *OOSC* §11.6 applies: it has no
  preconditions on content, and malformed input comes back as
  `OnePlaylist.Formats.UnreadablePlaylist` rather than as a contract violation.
  What it owes the rest of the application is the other half of that bargain —
  its postconditions must meet the preconditions of what comes next. See
  `every_track_is_usable` on the callback below.
  """

  alias OnePlaylist.Formats.UnreadablePlaylist
  alias OnePlaylist.Music.Track

  use Bond.Behaviour

  @typedoc "How a format identifies a track, and therefore what it is good for."
  @type kind :: :metadata_based | :path_based

  @doc """
  This format's kind. See the module documentation.
  """
  @callback kind() :: kind()

  @doc """
  Filename extensions this format claims, lowercase and without the dot.
  """
  @callback extensions() :: [String.t(), ...]

  @doc """
  Reads a playlist file into tracks, in the order the file lists them.
  """
  # The two laws that make a parsed track safe to hand onwards, stated where the
  # untrusted input stops being untrusted.
  #
  # These precede the `@callback` they belong to: `Bond.Behaviour` attaches
  # `@pre`/`@post` to the *following* callback, so writing them underneath
  # silently moves them onto the next one. Put below, `parse/2`'s postconditions
  # land on `render/2`, where `tracks` is not even bound — and the only sign is
  # a compiler warning about an unused variable in a generated function.
  #
  # `every_track_is_identifiable` is `Track`'s own invariant restated as an
  # obligation on the parser, because a codec builds tracks from nothing and has
  # to invent the id. `Track`'s invariant would catch a violation, but only once
  # the value reached one of *its* functions — which for an id-less track might
  # be after `Runner`'s snapshot-and-diff had already conflated two rows.
  #
  # `every_track_is_usable` is the filter's debt to
  # `c:OnePlaylist.Providers.Adapter.search_tracks/3`, whose `searchable`
  # precondition **raises**. A row with neither a title nor an ISRC cannot be
  # searched for, so a codec must reject it rather than pass it on: the user
  # gets "row 47 has no title" instead of a `Bond.PreconditionError` from three
  # layers away.
  @post whenever(
          {:ok, tracks} <- result,
          every_track_is_identifiable:
            forall(t <- tracks, is_binary(t.provider_id) and t.provider_id != ""),
          every_track_is_usable:
            forall(
              t <- tracks,
              is_binary(t.isrc) or (is_binary(t.title) and String.trim(t.title) != "")
            )
        )
  @callback parse(content :: binary(), opts :: keyword()) ::
              {:ok, [Track.t()]} | {:error, UnreadablePlaylist.t()}

  @doc """
  Writes tracks as this format.

  Returns `iodata` rather than a binary so a large playlist is not copied on its
  way to a socket or a file.
  """
  @callback render(tracks :: [Track.t()], opts :: keyword()) :: iodata()
end
