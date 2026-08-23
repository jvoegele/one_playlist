defmodule OnePlaylist.Formats.UnreadablePlaylist do
  @moduledoc """
  A playlist file could not be read as the format it claimed to be.

  A **domain** error, and the distinction matters here more than usual: this is
  a file a person exported from somewhere else and uploaded, so a malformed one
  is the *expected* input rather than a bug. Nothing is down, retrying changes
  nothing, and the only useful response is telling the user what is wrong with
  their file — which is why every reason below names something they can see.

  `context` carries `:line` where a line is to blame, because "row 47 has no
  title" is actionable and "the file is invalid" is not.
  """

  use Errata.Error,
    default_message: "that playlist file could not be read",
    default_reason: :malformed,
    reasons: [
      :empty,
      :malformed,
      :no_header,
      :no_title_column,
      :nothing_usable,
      :too_large,
      :unknown_format
    ],
    code: "UNREADABLE_PLAYLIST",
    http_status: 422
end
