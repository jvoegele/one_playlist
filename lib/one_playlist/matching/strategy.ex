defmodule OnePlaylist.Matching.Strategy do
  @moduledoc """
  One rung of the matching ladder.

  A strategy answers a single question — *does this candidate match this source,
  by my kind of evidence?* — and it answers only about its own kind. The ISRC
  rung knows nothing about titles; the fuzzy rung never sees an identifier. The
  ladder in `OnePlaylist.Matching` is what puts them in order.

  ## Returning `nil` means "not my department"

  A strategy returns `nil` both when it cannot form an opinion (the source has
  no ISRC) and when it has one and it is negative (the ISRCs differ). Those look
  identical to the ladder, and deliberately so: either way this rung has not
  produced a match, and the next rung down should try. A strategy that returned
  `{0.0, evidence}` for "definitely not" would be indistinguishable from a
  terrible match and would have to be special-cased everywhere.

  ## Contracts

  Declared here, inherited by every rung via
  `use Bond, behaviours: [OnePlaylist.Matching.Strategy]`. There is no contract
  code in any of the four implementations, and a fifth rung — the pgvector one
  sketched in `docs/reference/domain.md` — gets them for free.
  """

  use Bond.Behaviour

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Track

  @typedoc """
  A strategy's opinion: how well this candidate matches, plus what convinced it.

  The score is the strategy's *own* `0.0..1.0` judgement. Placing it in the
  strategy's band is `OnePlaylist.Matching`'s job, so a rung never has to know
  what it is worth relative to the others.
  """
  @type opinion :: {float(), keyword()} | nil

  @doc """
  Which rung this is.

  Contracted for the same reason `OnePlaylist.Providers.Adapter.provider/0` is:
  a rung reporting a name the `Match` struct has never heard of would otherwise
  surface much later, as a `KeyError` from a band lookup, or — worse — as a
  match whose confidence silently failed to derive.
  """
  @post known_to_match: result in [:isrc, :upc_position, :text, :fuzzy]
  @callback strategy() :: Match.strategy()

  @doc """
  This rung's opinion of `candidate` as a match for `source`.

  The postcondition is a magnitude law, and the bug it catches is specific: a
  rung that sums its signals without dividing by their total weight returns
  something above `1.0`. Nothing raises. The value is then scaled into the
  rung's band, lands above the band's ceiling, and outranks rungs that are
  genuinely more trustworthy — an approximate fuzzy match beating an exact ISRC
  one, which is this product's worst failure mode wearing a plausible number.
  """
  @post whenever({raw, _evidence} <- result),
    in_unit_interval: raw >= 0.0 and raw <= 1.0
  @callback score(source :: Track.t(), candidate :: Track.t()) :: opinion()

  @doc false
  # Keeps the aliases above meaningful in the specs, which is where they earn
  # their place. Same device as `OnePlaylist.Providers.Adapter.__types__/0`.
  def __types__, do: {Match, Track}
end
