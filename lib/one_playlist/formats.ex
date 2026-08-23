defmodule OnePlaylist.Formats do
  @moduledoc """
  Playlist file formats: which ones exist, and reading and writing them.

  The counterpart to `OnePlaylist.Providers` for things that are files rather
  than services. `OnePlaylist.Formats.Codec` is the behaviour; this module is
  the registry and the way in.

      iex> alias OnePlaylist.Formats
      iex> Formats.for_filename("Road Trip.csv")
      {:ok, :csv}

  ## Import and export are not mirror images

  Worth stating here because the shape of everything downstream follows from it:

    * **Import** is a source with no catalogue. `parse/3` produces tracks with
      whatever metadata the file happened to carry — often a title and an artist
      and nothing else — and the matching engine then does all the work, on the
      worst input it will ever see. Rungs 1 and 2 are usually dead on arrival.
    * **Export** is a destination that cannot fail to match. `render/3` writes
      what it is given; there is no search, no confidence, and no report worth
      reading.

  Treating the two as one symmetric "file provider" would give every codec a
  `search_tracks/3` with nothing to search.

  ## Not every format can leave a streaming service

  `kind/1` answers `:metadata_based` or `:path_based`, and the difference is not
  cosmetic — see `OnePlaylist.Formats.Codec`. A `:path_based` format identifies
  tracks by filesystem path, so exporting one from TIDAL would produce a file of
  paths that exist nowhere.

  There is deliberately no `exportable_from?/2` yet. Every format registered
  here is `:metadata_based`, so such a function could only contain a branch
  nothing reaches — Elixir's type checker says so outright. It belongs in the
  commit that adds M3U, alongside a test that can fail.
  """

  use Bond

  alias OnePlaylist.Formats.Codec
  alias OnePlaylist.Formats.UnreadablePlaylist
  alias OnePlaylist.Music.Track

  use Errata

  @codecs %{csv: OnePlaylist.Formats.Csv}

  @typedoc "A format this application can read or write."
  @type format :: :csv

  @doc """
  Every format that can be read or written.

      iex> OnePlaylist.Formats.known()
      [:csv]
  """
  @spec known() :: [format()]
  def known, do: @codecs |> Map.keys() |> Enum.sort()

  @doc """
  The module implementing a format.
  """
  @spec codec(format()) :: {:ok, module()} | {:error, UnreadablePlaylist.t()}
  def codec(format) do
    case Map.fetch(@codecs, format) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         Errata.create(UnreadablePlaylist,
           reason: :unknown_format,
           message: "no reader for that format",
           context: %{format: format, known: known()}
         )}
    end
  end

  @doc """
  The format a filename claims, by extension.

  By extension and nothing else. Sniffing the content would let a `.csv` that is
  really an M3U import as one long unmatched title, which is worse than being
  told the extension is wrong.

      iex> alias OnePlaylist.Formats
      iex> {Formats.for_filename("export.CSV"), Formats.for_filename("mix.m3u")}
      {{:ok, :csv}, {:error, :unknown_format}}
  """
  @spec for_filename(String.t()) :: {:ok, format()} | {:error, :unknown_format}
  def for_filename(filename) when is_binary(filename) do
    extension = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    Enum.find_value(@codecs, {:error, :unknown_format}, fn {format, module} ->
      if extension in module.extensions(), do: {:ok, format}
    end)
  end

  @doc """
  How a format identifies a track. See `OnePlaylist.Formats.Codec`.
  """
  @spec kind(format()) :: Codec.kind() | nil
  def kind(format) do
    case Map.fetch(@codecs, format) do
      {:ok, module} -> module.kind()
      :error -> nil
    end
  end

  @doc """
  Reads a playlist file.

  Delegates to the codec; see `c:OnePlaylist.Formats.Codec.parse/2` for the
  guarantees every format owes its caller.
  """
  @spec parse(format(), binary(), keyword()) ::
          {:ok, [Track.t()]} | {:error, UnreadablePlaylist.t()}
  def parse(format, content, opts \\ []) when is_binary(content) do
    with {:ok, module} <- codec(format), do: module.parse(content, opts)
  end

  @doc """
  Writes tracks as a playlist file.
  """
  # A precondition rather than an error tuple, unlike `parse/3`. The asymmetry is
  # the filter rule: `parse/3` faces a person's uploaded file, where a bad format
  # is expected input, while `render/3` is called by this application with a
  # format it chose — so an unknown one here is our bug, not theirs.
  @pre format_is_known: format in known()
  @spec render(format(), [Track.t()], keyword()) :: iodata()
  def render(format, tracks, opts \\ []) when is_list(tracks) do
    {:ok, module} = codec(format)
    module.render(tracks, opts)
  end
end
