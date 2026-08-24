defmodule OnePlaylist.Music.Work do
  @moduledoc """
  The piece a classical track is a movement of, read out of its title.

  ## Why classical needs its own reading of a title

  Every other rung of the ladder assumes two things that classical breaks.

  **That both sides credit the same act.** A classical source credits the
  *composer* — Antonio Vivaldi — and a catalogue credits the *performer* —
  Nigel Kennedy. The credits share no name, so `Signals.credit_match/4` answers
  `:unrelated` and the text rung refuses before scoring anything. Measured on a
  real library: **0 of 8** classical tracks matched.

  **That the identifying information is in the metadata fields.** It is not. It
  is inside the title, as prose, in an order each catalogue chooses for itself:

      source     The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro
      candidate  The Four Seasons, Violin Concerto in E Major, Op. 8 No. 1, RV 269 "Spring": I. Allegro

  `Op. 8 No. 1` is an identifier. `RV 269` is the same identifier in another
  system. `I.` names the movement. Compared as words those two strings score
  0.425 — *below* a recording of a different concerto entirely, which scored
  0.494 on the same query. No amount of threshold tuning fixes that; the
  information has to be parsed rather than compared.

  ## What a signature holds

  Whatever the title carries, and titles are inconsistent about which:

    * `catalogue` — `Op. 8 No. 1`, `BWV 1047`, `RV 269`, `K. 525`, `Op. 120/1`.
      A set, because a title often gives two systems for one work and either may
      be the one the other side used.
    * `form` and `number` — "Concerto grosso", "Brandenburg Concerto", plus
      "No. 2". The fallback when there is no catalogue number, which is the
      largest single bucket in a real library.
    * `key` — `in F major`. Never enough to identify a work and often enough to
      *rule one out*.
    * `movement` — a roman numeral, a tempo marking, or both.

  A signature with neither a catalogue number nor a usable form-and-number
  identifies nothing, and `identifies_work?/1` says so.
  """

  use Bond

  @type t :: %__MODULE__{
          catalogue: MapSet.t({String.t(), String.t(), String.t() | nil}),
          form: String.t() | nil,
          number: String.t() | nil,
          key: {String.t(), String.t(), String.t()} | nil,
          roman: String.t() | nil,
          tempo: String.t() | nil
        }

  defstruct catalogue: nil, form: nil, number: nil, key: nil, roman: nil, tempo: nil

  # Ordered longest-first so `bwv` is not read as `b`, and `kv` not as `k`.
  # `Op. 120/1` and `Op. 8 No. 1` are the same shape with different punctuation.
  @catalogue ~r/\b(bwv|hwv|kv|rv|woo|op|k|d)\.?\s*(\d+)(?:\s*\/\s*(\d+))?(?:\s*(?:no|nr)\.?\s*(\d+))?/iu

  @number ~r/\b(?:no|nr)\.?\s*(\d+)/iu

  @key ~r/\bin\s+([a-g])[-\s]*(sharp|flat|#|b)?\s*(major|minor)\b/iu

  # The movement, by either convention. A title may carry both — "III. Rondeau:
  # Vivace" — and either may be all the other side gives.
  @roman ~r/\b([ivx]+)\s*[.:]/iu

  @tempo ~r/\b(allegretto|allegro|adagio|andante|larghetto|largo|presto|moderato|vivace|lento|grave|maestoso|scherzo|menuetto|minuet|rondeau|rondo|romance|finale|aria|sarabande|gigue|courante|gavotte|passacaglia)\w*/iu

  # Named forms, longest first: "concerto grosso" must not be read as "concerto".
  @form ~r/\b(concerto grosso|brandenburg concerto|piano concerto|violin concerto|organ concerto|cello concerto|double concerto|string quartet|piano quintet|concerto|symphony|sonata|quartet|quintet|septet|suite|partita|prelude|fugue|nocturne|etude|ballade|mazurka|polonaise|mass|requiem|cantata|oratorio)\b/iu

  # A form so generic it says nothing about *which* work. A composer writes
  # concertos for several instruments and numbers each series separately, so
  # "Concerto No. 2 in G minor" is two different Vivaldi works — one for two
  # cellos, one for violin — and the form-and-number path matched them to each
  # other until these were excluded from it.
  #
  # A qualified form does not have that problem: "Concerto grosso No. 2",
  # "Piano Concerto No. 2" and "Brandenburg Concerto No. 2" each name one piece.
  @ambiguous_forms ~w(concerto sonata suite prelude fugue aria)

  @doc """
  Reads a work signature out of a title.

  Tolerant by design: a pop song produces an empty signature rather than an
  error, which is what makes this safe to run over every track.

      iex> alias OnePlaylist.Music.Work
      iex> work = Work.parse("The Four Seasons - The Spring, Op. 8 No. 1: I. Allegro")
      iex> {MapSet.to_list(work.catalogue), work.roman, work.tempo}
      {[{"op", "8", "1"}], "i", "allegro"}

      iex> alias OnePlaylist.Music.Work
      iex> work = Work.parse("Brandenburg Concerto no. 2 in F major: Allegro assai")
      iex> {work.form, work.number, work.key}
      {"brandenburg concerto", "2", {"f", "", "major"}}

      iex> alias OnePlaylist.Music.Work
      iex> Work.identifies_work?(Work.parse("Yesterday"))
      false
  """
  @spec parse(String.t() | nil) :: t()
  def parse(title) when is_binary(title) do
    folded = fold(title)

    %__MODULE__{
      catalogue: catalogue(folded),
      form: first_capture(@form, folded),
      number: first_capture(@number, folded),
      key: key(folded),
      roman: first_capture(@roman, folded),
      tempo: tempo(folded)
    }
  end

  def parse(_title), do: %__MODULE__{catalogue: MapSet.new()}

  @doc """
  Whether this signature names a work at all.

  A catalogue number does it alone. Failing that it takes a **qualified** form
  and a number: "Symphony No. 2" identifies a piece, "Concerto No. 2" does not,
  and neither does "No. 2" by itself.
  """
  @spec identifies_work?(t()) :: boolean()
  def identifies_work?(%__MODULE__{} = work) do
    (work.catalogue && MapSet.size(work.catalogue) > 0) or usable_form?(work)
  end

  @doc """
  Whether two signatures name the same work.

  A shared catalogue number settles it. Otherwise the form and number must
  agree. In both cases a stated key that *disagrees* overrules the rest — two
  recordings of Op. 1 No. 2 in different keys are different works, and one of
  the titles is wrong about its number.
  """
  # Symmetric, and it has to be: which track is the source is an accident of
  # which service somebody is transferring from. An asymmetric answer would make
  # the same pair match in one direction and not the other.
  @post symmetric: result == same_work?(right, left)
  @spec same_work?(t(), t()) :: boolean()
  def same_work?(%__MODULE__{} = left, %__MODULE__{} = right),
    do: identified_by(left, right) != nil

  @doc """
  *How* two signatures agree on a work, or `nil` if they do not.

  The distinction matters because the two are not equally good evidence.

    * `:catalogue` — they share a catalogue number. `Op. 8 No. 1` names one
      concerto and nothing else, so this is nearly an identifier.
    * `:form` — no shared catalogue number, but the same qualified form and the
      same number. Weaker, and a caller should corroborate it — see
      `OnePlaylist.Matching.Strategy.Work`, which additionally requires the
      titles to agree.
  """
  @post symmetric_too: result == identified_by(right, left)
  @spec identified_by(t(), t()) :: :catalogue | :form | nil
  def identified_by(%__MODULE__{} = left, %__MODULE__{} = right) do
    cond do
      not (identifies_work?(left) and identifies_work?(right)) -> nil
      key_conflict?(left, right) -> nil
      shared_catalogue?(left, right) -> :catalogue
      same_form_and_number?(left, right) -> :form
      true -> nil
    end
  end

  @doc """
  Whether two signatures name the same movement.

  `true` when neither says: a single-movement work, or a title that names none,
  is not evidence against. Only a stated disagreement counts.
  """
  @spec same_movement?(t(), t()) :: boolean()
  def same_movement?(%__MODULE__{} = left, %__MODULE__{} = right) do
    cond do
      left.roman && right.roman -> left.roman == right.roman
      left.tempo && right.tempo -> left.tempo == right.tempo
      true -> true
    end
  end

  @doc """
  How much of the signature the two have in common, in `0.0..1.0`.

  For choosing between recordings of one work, not for deciding whether to
  match — every pair reaching this has already agreed on the work.
  """
  @post is_a_proportion: result >= 0.0 and result <= 1.0
  @spec agreement(t(), t()) :: float()
  def agreement(%__MODULE__{} = left, %__MODULE__{} = right) do
    checks = [
      shared_catalogue?(left, right),
      left.key != nil and left.key == right.key,
      left.roman != nil and left.roman == right.roman,
      left.tempo != nil and left.tempo == right.tempo,
      left.form != nil and left.form == right.form
    ]

    Enum.count(checks, & &1) / length(checks)
  end

  @doc """
  Adds what another signature knows, keeping what this one already had.

  For enriching a source's own reading of its title with a catalogue number
  supplied from elsewhere. Only *adds*: the source's key, movement and form are
  what the user's file says, and an outside answer about a work should not
  overwrite them — it is answering "what is this piece called", not "which
  movement did you mean".
  """
  # A merge that lost a catalogue number would silently undo the lookup it
  # exists to apply, and the symptom would be a track that stayed unmatched for
  # no visible reason.
  @post keeps_both_catalogues:
          MapSet.subset?(left.catalogue, result.catalogue) and
            MapSet.subset?(right.catalogue, result.catalogue)
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      left
      | catalogue: MapSet.union(left.catalogue || MapSet.new(), right.catalogue || MapSet.new()),
        form: left.form || right.form,
        number: left.number || right.number,
        key: left.key || right.key
    }
  end

  defp usable_form?(%__MODULE__{} = work) do
    is_binary(work.form) and work.form not in @ambiguous_forms and is_binary(work.number)
  end

  defp shared_catalogue?(%{catalogue: left}, %{catalogue: right})
       when left != nil and right != nil,
       do: not MapSet.disjoint?(left, right)

  defp shared_catalogue?(_left, _right), do: false

  defp same_form_and_number?(left, right) do
    usable_form?(left) and left.form == right.form and left.number == right.number
  end

  # Only when both state one. A title that omits the key is silent, not
  # disagreeing.
  defp key_conflict?(%{key: left}, %{key: right})
       when left != nil and right != nil,
       do: left != right

  defp key_conflict?(_left, _right), do: false

  defp catalogue(folded) do
    @catalogue
    |> Regex.scan(folded)
    |> Enum.map(fn
      [_all, system, number] -> {system, number, nil}
      [_all, system, number, sub] -> {system, number, blank_to_nil(sub)}
      [_all, system, number, sub, no] -> {system, number, blank_to_nil(sub) || blank_to_nil(no)}
    end)
    |> MapSet.new()
  end

  defp key(folded) do
    case Regex.run(@key, folded) do
      [_all, note, accidental, mode] -> {note, accidental, mode}
      [_all, note, mode] -> {note, "", mode}
      _none -> nil
    end
  end

  # The first tempo word, so "allegro assai" and "allegro" agree while
  # "allegretto" stays distinct from "allegro".
  defp tempo(folded) do
    case Regex.run(@tempo, folded) do
      [_all, word] -> String.downcase(word)
      _none -> nil
    end
  end

  defp first_capture(regex, folded) do
    case Regex.run(regex, folded) do
      [_all, capture | _rest] -> String.downcase(capture)
      _none -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Diacritics folded and case dropped, so "Préludes" and "Preludes" read alike.
  defp fold(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end
end
