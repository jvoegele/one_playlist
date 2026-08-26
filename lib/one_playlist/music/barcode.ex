defmodule OnePlaylist.Music.Barcode do
  @moduledoc """
  Release barcodes — UPC and EAN — reduced to a comparable form.

  A barcode identifies a *release*, which makes it the second rung of the
  matching ladder: two tracks at the same position on the same release are the
  same recording, and that holds even when neither side carries an ISRC. It is
  also the cache key `OnePlaylist.Catalogue` stores album lookups under.

  ## The same number, written two ways

  A UPC is twelve digits and an EAN is thirteen, and the thirteen-digit form of
  a twelve-digit barcode is the same number with a zero in front. Services
  disagree about which to report: TIDAL sends `"00602547670052"` for a release
  that catalogues elsewhere print as `"602547670052"`.

  Compared as written, those are different strings. Nothing raises — rung 2
  simply never fires across services, silently and completely, which is the
  worst shape a matching bug can have.

  ## Why this is its own module

  Barcode comparison is first needed by `OnePlaylist.Matching.Signals`, but the
  callers are `OnePlaylist.Catalogue`, `OnePlaylist.Providers.Tidal` and
  `OnePlaylist.Matching.Strategy.UpcPosition` — none of which are about
  comparing two tracks.

  Bond is what makes that visible. `Signals` declares an `@invariant`, and
  Bond's linter warns when such a module has a public function that never
  mentions its struct: the entry check is skipped, so the function is not what
  the module is about. Housing this here means there is no warning to suppress,
  which is what the linter was asking for.
  """

  use Bond

  @doc """
  Reduces a barcode to digits, without leading zeros; `nil` when there is
  nothing left.

  `nil` rather than `""` for an unusable value, so a caller cannot accidentally
  key a cache or test equality on the empty string — two releases with no
  barcode are not the same release.

      iex> alias OnePlaylist.Music.Barcode
      iex> Barcode.normalize("00602547670052")
      "602547670052"
      iex> Barcode.normalize("602547670052")
      "602547670052"

  Separators are stripped, because a barcode is sometimes printed in groups:

      iex> alias OnePlaylist.Music.Barcode
      iex> Barcode.normalize("6-025 476.70052")
      "602547670052"

  Nothing usable becomes `nil`:

      iex> alias OnePlaylist.Music.Barcode
      iex> {Barcode.normalize(""), Barcode.normalize("no digits"), Barcode.normalize("0000")}
      {nil, nil, nil}

  ## What a normalized barcode is

  Digits only, no leading zeros, or `nil` — `normalized_form` below, and what
  every caller relies on. `OnePlaylist.Catalogue.album_id/3` states its own
  precondition against this function, so the definition has to live here.

  Two plausible rewrites break it silently. Dropping the non-digit strip leaves
  `"6-025 476.70052"` intact, so it never equals another service's digits and
  rung 2 stops firing across providers. Returning `""` rather than `nil` for an
  unusable value gives the catalogue cache an empty-string key shared by every
  barcode-less release.

  Normalizing is also **idempotent**, which is a separate claim rather than a
  consequence — see `idempotent` below.
  """
  # `normalized_form` does not catch the trailing-zero bug: `String.trim/2` for
  # `String.trim_leading/2` truncates `"602547670050"` to `"60254767005"`, still
  # a leading-zero-free digit string. A wrong value that is structurally fine
  # belongs to the example tests.
  @post normalized_form: is_nil(result) or Regex.match?(~r/^[1-9][0-9]*$/, result)
  # Separate from `normalized_form` rather than implied by it: slicing off the
  # trailing check digit turns `"00602547670052"` into `"60254767005"`, which
  # satisfies the shape perfectly and normalizes again to `"6025476700"`. Only
  # idempotence notices.
  #
  # It belongs *here* by Meyer's Assertion Violation rule. `Catalogue.album_id/3`
  # requires `barcode == normalize(barcode)`, so a non-idempotent `normalize/1`
  # makes that precondition unsatisfiable — and it would fire as a *precondition*
  # violation, accusing a client that normalized exactly once as instructed.
  #
  # Last because it re-enters the function, so the cheaper checks fail first.
  @post idempotent: normalize(result) == result
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(value) when is_binary(value) do
    case value |> String.replace(~r/\D/, "") |> String.trim_leading("0") do
      "" -> nil
      digits -> digits
    end
  end
end
