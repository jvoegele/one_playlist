defmodule OnePlaylist.Formats.Csv do
  @moduledoc """
  Comma-separated playlists — the interchange format the incumbents export.

  `:metadata_based`, so it crosses service boundaries: every column means the
  same thing to TIDAL as to Navidrome.

  ## Strict on the way out, permissive on the way in

  `render/2` writes exactly one header, documented below. `parse/2` accepts a
  great deal more, because the files people upload were written by Soundiiz,
  TuneMyMusic, Excel, or a script somebody wrote once — and none of them agree
  on what the title column is called.

  What it will **not** do is guess at column *order*. A headerless file is
  rejected rather than assumed to be `artist,title`, because the failure mode of
  guessing wrong is an entire playlist imported with artist and title swapped,
  which matches nothing and looks like the matching engine is broken.

  ## The columns we write

      title,artists,album,isrc,duration_seconds,track_number,disc_number,version,album_upc,explicit

  `parse/2` recognises these and the common aliases in `@aliases` — `track name`,
  `artist`, `song`, `length`, and so on — case-insensitively, ignoring
  surrounding whitespace and a leading UTF-8 BOM.

  ## Artists are joined with `;`

  Because a comma is the field separator and a slash appears inside real artist
  names. On the way back in, a field is split on `;` **and on nothing else**.

  That restraint is deliberate. Splitting on `,`, `&`, `feat.` or `x` would turn
  *Earth, Wind & Fire* into three artists and *Simon & Garfunkel* into two, and
  the matching engine would then fail to find either. The Subsonic mapper makes
  the same call for the same reason: prefer the structured field, never guess at
  a separator you did not write.

  ## Round-tripping

  Rendering and re-parsing is **not** the identity, and cannot be: `provider`
  and `provider_id` describe where a track came from, which a file does not
  know, and `popularity` is one service's opinion. What holds instead is a
  fixpoint one step in —

      parse(render(parse(csv))) == parse(csv)

  — which is the law `csv_property_test.exs` checks, and the stronger claim of
  the two. It says the format loses nothing *it carries*, however many times a
  playlist goes round.
  """

  # `use Bond, behaviours:` rather than a bare `@behaviour`: that is what draws
  # `Codec`'s inherited contracts into this module. With only `@behaviour` the
  # callback's postconditions compile fine and are never applied to anything,
  # silently — which is why the two tests at the bottom of `csv_test.exs` prove
  # they fire.
  use Bond, behaviours: [OnePlaylist.Formats.Codec]
  use Errata

  alias OnePlaylist.Formats.UnreadablePlaylist
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Payload

  # `NimbleCSV.RFC4180` rather than a `NimbleCSV.define/2` of our own. A private
  # definition of the standard we claim to implement is a place to drift from
  # it, and the drift is invisible: the obvious hand-written copy differs only
  # in line endings. The golden test in `csv_test.exs` is what pins this.
  #
  # It reads both line endings and writes CRLF, which is the "strict out,
  # permissive in" rule this module follows everywhere else.
  alias NimbleCSV.RFC4180, as: Comma

  # RFC 4180 in every respect except the separator. Both exist because real
  # exporters use them: Roon writes `;`, and a spreadsheet saved as "CSV" in a
  # European locale does too, because `,` is the decimal point there. Tab is the
  # third thing people mean when they say CSV.
  NimbleCSV.define(OnePlaylist.Formats.Csv.Semicolon,
    separator: ";",
    escape: "\"",
    line_separator: "\r\n"
  )

  NimbleCSV.define(OnePlaylist.Formats.Csv.Tab,
    separator: "\t",
    escape: "\"",
    line_separator: "\r\n"
  )

  # Comma first, so it wins a tie — `Enum.max_by/2` keeps the first maximal
  # element, and a single-column file parses identically under all three.
  @parsers [
    {",", Comma},
    {";", OnePlaylist.Formats.Csv.Semicolon},
    {"\t", OnePlaylist.Formats.Csv.Tab}
  ]

  @columns ~w(title artists album isrc duration_seconds track_number disc_number version
              album_upc explicit)

  # What other people's exports call our columns. Lowercased and trimmed before
  # lookup, so only the spelling varies here.
  @aliases %{
    "track" => "title",
    "track name" => "title",
    "song" => "title",
    "song name" => "title",
    "name" => "title",
    "artist" => "artists",
    "artist name" => "artists",
    "artist(s)" => "artists",
    "album name" => "album",
    "duration" => "duration_seconds",
    "length" => "duration_seconds",
    "time" => "duration_seconds",
    "track number" => "track_number",
    "track #" => "track_number",
    "disc" => "disc_number",
    "disc number" => "disc_number",
    "volume_number" => "disc_number",
    "upc" => "album_upc",
    "barcode" => "album_upc",
    # Roon's spreadsheet export, which is the likely route in: Roon writes an
    # .xlsx, the user opens it in Excel and saves as CSV. Its header row is
    # `Album Artist, Album, Disc#, Track#, Title, Track Artist(s), ...`.
    "track artist" => "artists",
    "track artist(s)" => "artists",
    "disc#" => "disc_number",
    "track#" => "track_number"
    #
    # `Album Artist` is deliberately **not** aliased to `artists`. On a
    # compilation it is "Various Artists", which is not the performer of any
    # track on it — mapping it would give every row an artist that matches
    # nothing, and a wrong artist is worse than none: the text rung needs
    # `artists_agree`, so a confident wrong value rejects the right candidate
    # where an absent one would have let the title carry the match.
  }

  @artist_separator ";"

  @impl true
  def kind, do: :metadata_based

  @impl true
  def extensions, do: ["csv"]

  @doc """
  Reads a CSV export into tracks, in file order.

  ## Options

    * `:provider` — the provider atom to stamp on each track. Defaults to
      `:file`. Exists so a caller importing a known service's export can say so.

  Rows that carry neither a title nor an ISRC are dropped rather than returned:
  they cannot be searched for, and
  `c:OnePlaylist.Providers.Adapter.search_tracks/3`'s precondition would raise
  on them. A file of *nothing but* such rows is an error, because silently
  importing zero tracks from a file with content in it is worse than saying why.
  """
  # `@post_strengthen`, not `@post`: `Codec`'s `every_track_is_identifiable` and
  # `every_track_is_usable` already apply here through `use Bond, behaviours:`,
  # and the effective postcondition is theirs **and** these. Two laws this
  # format owes that the behaviour cannot state, because they are about what a
  # CSV specifically carries.
  #
  # `isrcs_are_canonical` is the seam to TIDAL. Storing the file's own spelling
  # looks safe — comparison normalises anyway — and is not, because
  # `Tidal.candidates/3` sends the code *to the provider*, and TIDAL rejects a
  # lower-case one. Roon writes them lower case, so this is the common path
  # rather than an edge: without it, an imported Roon playlist silently loses
  # rung 1 for every track and falls back to matching by name.
  #
  # `positions_are_unique` is the stronger half of `every_track_is_identifiable`.
  # The behaviour asks only that an id exist; a file's ids are row numbers, and
  # two tracks sharing one is what `Track`'s `identifiable` invariant is really
  # protecting against — `Runner`'s snapshot-and-diff would treat the two rows as
  # one track and the second would never be transferred. Duplicates are legal for
  # a *recording* here and illegal for a row index, which is why this is safe to
  # assert where `docs/reference/contracts.md` warns uniqueness usually is not.
  #
  # Both proven by mutation: dropping `Isrc.normalize/1` in `track/4` fires the
  # first on any lower-case fixture, and numbering with a constant fires the
  # second.
  # `match?/2` with `~>` rather than a `whenever`: `@post_strengthen` does not
  # take a binding form, and `~>` short-circuits, so `elem(result, 1)` is never
  # reached on an `{:error, _}`.
  @post_strengthen isrcs_are_canonical:
                     match?({:ok, _}, result)
                     ~> forall(track <- elem(result, 1), Isrc.normalize(track.isrc) == track.isrc)
  @post_strengthen positions_are_unique:
                     match?({:ok, _}, result)
                     ~> (length(Enum.uniq_by(elem(result, 1), & &1.provider_id)) ==
                           length(elem(result, 1)))
  @impl true
  def parse(content, opts \\ [])

  def parse(<<0x50, 0x4B, 0x03, 0x04>> <> _rest, _opts) do
    # A ZIP, and in this context almost always an .xlsx — Roon exports both CSV
    # and XLSX, and the spreadsheet is the one that looks more like a playlist to
    # a person. Parsing it as text gives `:no_header` from a file that plainly
    # has one, so it is worth the four bytes to say what actually happened.
    #
    # The message names the *reason* rather than just the remedy, because the
    # reason is the useful part and it is measured rather than assumed. Both of
    # Roon's exports of one 58-track playlist were compared: the CSV carries an
    # ISRC for 57 of 58 tracks, and the spreadsheet carries none at all — no
    # ISRC column exists in it. That is the difference between rung 1 resolving
    # almost everything exactly and nothing being resolved exactly.
    #
    # Which is also why this application does not read spreadsheets. Doing so
    # would mean importing the weaker of the two files a user already has. See
    # docs/reference/domain.md.
    {:error,
     Errata.create(UnreadablePlaylist,
       reason: :looks_like_a_spreadsheet,
       message:
         "that is a spreadsheet, not a CSV. Export CSV instead if you can — a " <>
           "spreadsheet export usually leaves out the ISRC, which is what lets " <>
           "tracks be matched exactly rather than by name"
     )}
  end

  def parse(content, opts) when is_binary(content) do
    provider = Keyword.get(opts, :provider, :file)

    with {:ok, rows} <- rows(content),
         {:ok, header, body} <- split_header(rows),
         {:ok, index} <- column_index(header) do
      tracks =
        body
        |> Enum.with_index(1)
        |> Enum.map(fn {row, position} -> track(row, index, position, provider) end)
        |> Enum.reject(&is_nil/1)

      if tracks == [] do
        {:error,
         Errata.create(UnreadablePlaylist,
           reason: :nothing_usable,
           message: "no row in that file had a title or an ISRC"
         )}
      else
        {:ok, tracks}
      end
    end
  end

  @doc """
  Writes tracks as CSV, header first.

  Always quotes, which costs a few bytes and removes an entire class of bug: a
  title containing a comma, a quote, or a newline is common enough in real
  catalogues that unquoted output is wrong rather than merely risky.
  """
  @impl true
  def render(tracks, opts \\ [])

  def render(tracks, _opts) when is_list(tracks) do
    Comma.dump_to_iodata([@columns | Enum.map(tracks, &row/1)])
  end

  # ---------------------------------------------------------------------------

  defp rows(content) do
    content = strip_bom(content)

    parser = parser_for(content)

    content
    |> parser.parse_string(skip_headers: false)
    |> case do
      [] -> {:error, Errata.create(UnreadablePlaylist, reason: :empty)}
      rows -> {:ok, rows}
    end
  rescue
    # NimbleCSV raises on genuinely malformed CSV — an unterminated quote, most
    # often, which is what a truncated download looks like.
    error in [NimbleCSV.ParseError] ->
      {:error,
       Errata.create(UnreadablePlaylist,
         reason: :malformed,
         message: Exception.message(error)
       )}
  end

  # Which separator this file uses, decided by whichever one makes the header row
  # into the most column names we recognise.
  #
  # This is not sniffing the *content*, which `OnePlaylist.Formats.for_filename/1`
  # deliberately refuses to do. It is choosing the reading under which the file
  # has a header we understand — and if none of them does, `column_index/1`
  # rejects the file exactly as before. A comma-separated file scored under `;`
  # yields one unrecognised column, so the comparison is not close.
  defp parser_for(content) do
    header = content |> String.split(["\r\n", "\n"], parts: 2) |> List.first() || ""

    {_separator, parser} =
      Enum.max_by(@parsers, fn {separator, _parser} -> recognised_columns(header, separator) end)

    parser
  end

  defp recognised_columns(header, separator) do
    header |> String.split(separator) |> Enum.count(&(canonical(&1) != nil))
  end

  # Excel writes UTF-8 with a byte order mark, and it lands on the first header
  # cell — so `"﻿title"` would not match `"title"` and the file would be
  # rejected as having no title column. Costs one clause, saves a support email.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  # No empty clause: `rows/1` has already rejected a file with no rows at all,
  # so by here there is always at least a header.
  defp split_header([header | body]), do: {:ok, header, body}

  # Maps our column names to their position in *this* file, so the rest of the
  # module never thinks about column order.
  defp column_index(header) do
    index =
      header
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {name, position}, acc ->
        case canonical(name) do
          nil -> acc
          column -> Map.put_new(acc, column, position)
        end
      end)

    cond do
      index == %{} ->
        {:error,
         Errata.create(UnreadablePlaylist,
           reason: :no_header,
           message:
             "the first row must name the columns — expected one of " <>
               "#{Enum.join(Enum.sort(Map.keys(@aliases)) ++ @columns, ", ")}",
           context: %{first_row: Enum.take(header, 8)}
         )}

      not Map.has_key?(index, "title") and not Map.has_key?(index, "isrc") ->
        {:error,
         Errata.create(UnreadablePlaylist,
           reason: :no_title_column,
           message: "that file has no title column and no ISRC column",
           context: %{columns_found: Map.keys(index)}
         )}

      true ->
        {:ok, index}
    end
  end

  defp canonical(name) when is_binary(name) do
    normalized = name |> strip_bom() |> String.trim() |> String.downcase()

    if normalized in @columns, do: normalized, else: Map.get(@aliases, normalized)
  end

  defp canonical(_name), do: nil

  # `nil` for a row that cannot become a searchable track. The caller drops it.
  defp track(row, index, position, provider) do
    title = Payload.text(at(row, index, "title"))

    # Canonicalised here rather than stored as written. Keeping the file's
    # spelling looks safe, because comparison normalises anyway — and is not
    # enough: `Tidal.candidates/3` sends the ISRC to the provider, and TIDAL
    # rejects a lower-case one. Roon writes them lower case. See
    # `OnePlaylist.Music.Isrc`.
    isrc = row |> at(index, "isrc") |> Payload.text() |> Isrc.normalize()

    if is_nil(title) and is_nil(isrc) do
      nil
    else
      %Track{
        provider: provider,
        # The row's position in the file. Unique within the playlist, which is
        # what `Track`'s `identifiable` invariant is protecting — two id-less
        # tracks compare equal and `Runner`'s snapshot-and-diff would treat them
        # as one. It is also the most useful thing to show a user next to an
        # unmatched row: "row 47" is somewhere they can look.
        provider_id: Integer.to_string(position),
        title: title,
        isrc: isrc,
        artists: artists(at(row, index, "artists")),
        album: Payload.text(at(row, index, "album")),
        album_upc: Payload.text(at(row, index, "album_upc")),
        duration_seconds: duration(at(row, index, "duration_seconds")),
        track_number: Payload.position(integer(at(row, index, "track_number"))),
        volume_number: Payload.position(integer(at(row, index, "disc_number"))),
        version: Payload.text(at(row, index, "version")),
        explicit: boolean(at(row, index, "explicit"))
      }
    end
  end

  defp at(row, index, column) do
    case Map.fetch(index, column) do
      {:ok, position} -> Enum.at(row, position)
      :error -> nil
    end
  end

  defp artists(nil), do: []

  defp artists(value) when is_binary(value) do
    value
    |> String.split(@artist_separator)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Accepts both what we write (`225`) and what a human-facing export writes
  # (`3:45`, `1:02:03`), because "duration" in someone else's CSV is usually the
  # second.
  defp duration(nil), do: nil

  defp duration(value) when is_binary(value) do
    case value |> String.trim() |> String.split(":") do
      [seconds] -> Payload.count(integer(seconds))
      parts -> parts |> Enum.map(&integer/1) |> from_clock()
    end
  end

  # `nil` if any component failed to parse, rather than treating it as zero:
  # `3:xx` is a value we do not understand, not three minutes exactly.
  defp from_clock(parts) do
    if Enum.all?(parts, &is_integer/1) do
      parts
      |> Enum.reduce(0, fn part, total -> total * 60 + part end)
      |> Payload.count()
    end
  end

  defp integer(nil), do: nil

  defp integer(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, _rest} -> number
      :error -> nil
    end
  end

  # Only the spellings a machine wrote. Anything else is `nil` — "not stated" —
  # rather than `false`, because guessing "clean" for an unrecognised value is a
  # claim about a recording rather than an absence of one.
  defp boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ~w(true yes y 1 explicit) -> true
      v when v in ~w(false no n 0 clean) -> false
      _otherwise -> nil
    end
  end

  defp boolean(_value), do: nil

  defp row(%Track{} = track) do
    [
      track.title,
      Enum.join(track.artists, "#{@artist_separator} "),
      track.album,
      track.isrc,
      track.duration_seconds,
      track.track_number,
      track.volume_number,
      track.version,
      track.album_upc,
      track.explicit
    ]
    |> Enum.map(&cell/1)
  end

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: value
  defp cell(value) when is_integer(value), do: Integer.to_string(value)
  defp cell(true), do: "true"
  defp cell(false), do: "false"
end
