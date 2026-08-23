defmodule OnePlaylist.Music.Isrc do
  @moduledoc """
  The International Standard Recording Code, in canonical form.

  `CC-XXX-YY-NNNNN` — country, registrant, year, designation — printed by
  different services with and without the hyphens, and by some in lower case.
  Twelve alphanumeric characters, upper case, is the form everything here
  compares and every provider accepts.

  ## Why this is not in the matching strategy any more

  `OnePlaylist.Matching.Strategy.Isrc` owned this, and that was one function too
  many for a module about *comparing* two tracks. The distinction was invisible
  until it cost something.

  A Roon export writes ISRCs in lower case. The matching rung normalised before
  comparing, so a lower-case identifier still matched correctly, and it looked
  like the case was handled. It was not: `Tidal.candidates/3` passes an ISRC
  straight to TIDAL's `filter[isrc]`, which rejects a lower-case one outright.
  Fifty-seven of fifty-eight tracks in a real import failed, and the one that
  succeeded was the only row in the file with no ISRC at all.

  So the canonical form belongs to the *identifier*, where a lookup can reach it
  too, not to one of the things that reads it. `OnePlaylist.Music.Barcode` was
  already this shape for UPCs.
  """

  use Bond

  @doc """
  Canonical form, or `nil` for anything that is not an ISRC.

      iex> alias OnePlaylist.Music.Isrc
      iex> Isrc.normalize("gb-aye-06-01477")
      "GBAYE0601477"
      iex> Isrc.normalize("ussm11100234")
      "USSM11100234"
      iex> Isrc.normalize("nonsense")
      nil

  Anything not twelve characters after stripping is rejected rather than
  returned. A truncated or malformed identifier that happens to equal another
  malformed one is not evidence of anything — and rung 1 compares for exact
  equality, so two tracks both carrying `""` would match perfectly.
  """
  # `normalized_form` is what every caller relies on without saying so: a
  # provider lookup, an exact-equality comparison, and a report all assume the
  # twelve upper-case characters. The bug this module was extracted for was
  # precisely a value that satisfied `String.t()` and none of this.
  @post normalized_form: is_nil(result) or Regex.match?(~r/^[A-Z0-9]{12}$/, result)
  # Normalising an already-canonical value must not change it. Not implied by
  # the rule above: a rewrite that stripped a leading character, or upcased and
  # then truncated, would satisfy the shape and lose information on the second
  # pass — and this value is stored, so a second pass is a matter of time.
  @post idempotent: normalize(result) == result
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(value) when is_binary(value) do
    normalized = value |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.upcase()

    if String.length(normalized) == 12, do: normalized
  end

  def normalize(_value), do: nil
end
