defmodule OnePlaylist.Matching.Strategy.Work do
  @moduledoc """
  Rung 3: the same movement of the same classical work.

  Sits above the text rungs because a catalogue number is nearly an identifier
  and a title is not. `Op. 8 No. 1` names one concerto; comparing the words
  around it ranked a recording of `Op. 8 No. 4` *higher*, which is how classical
  came to match 0 of 8 on a real library.

  ## The composer stands in for the credit

  Every other rung compares `artists` with `artists`. Here that is guaranteed to
  fail: the source credits **Antonio Vivaldi** and the catalogue credits
  **Nigel Kennedy**, and neither is wrong. So instead of requiring the credits
  to agree, this asks whether the source's credit *appears anywhere* in the
  candidate — its title, its album or its performers. `Vivaldi: The Four
  Seasons` is how a catalogue names the composer, and it is enough.

  Loose on its own, and it is not on its own: it is one of four conditions, and
  the work signature is the one carrying the weight.

  ## Why this cannot fire on pop music

  `Work.identifies_work?/1` needs a catalogue number, or a named form *and* a
  number. "Yesterday" has neither, so the gate closes before the composer check
  is reached. The rung is restricted to classical by the shape of the titles
  rather than by a guess about genre, which is the only honest way to tell.
  """

  use Bond, behaviours: [OnePlaylist.Matching.Strategy]

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Music.Work

  # The same band as the text rungs, so the score maps to the usual confidence
  # names and a work match reads as `:high` or `:medium` like anything else.
  # What distinguishes it in a report is the *strategy*, which is the honest
  # place for "how this was found".
  @floor 0.80
  @ceiling 0.98

  @impl true
  def strategy, do: :work

  @impl true
  def score(source, candidate)

  def score(%Track{} = source, %Track{} = candidate) do
    source_work = Work.parse(source.title)
    candidate_work = Work.parse(text_of(candidate))

    with true <- Work.same_movement?(source_work, candidate_work),
         true <- composer_present?(source, candidate),
         identification when not is_nil(identification) <-
           Work.identified_by(source_work, candidate_work),
         true <- corroborated?(identification, source, candidate) do
      {placement(source_work, candidate_work), evidence(source_work, candidate_work)}
    else
      _no -> nil
    end
  end

  # A shared catalogue number needs nothing else: `Op. 8 No. 1` names one work.
  #
  # The form-and-number path does. Vivaldi wrote a *Concerto for Two Cellos
  # No. 2 in G minor* and a violin concerto also numbered 2 in G minor, both
  # credited to Vivaldi, and "concerto" plus "2" plus "G minor" agrees for both
  # — which is exactly the wrong match this rung made before the paths were told
  # apart. The instrument is in the title and nowhere else, so the titles
  # themselves have to agree.
  @weak_path_floor 0.55

  defp corroborated?(:catalogue, _source, _candidate), do: true

  defp corroborated?(:form, source, candidate) do
    similarity = Signals.compare(source, candidate).title

    is_number(similarity) and similarity >= @weak_path_floor
  end

  # Title *and* album, because catalogues split the identifying information
  # between them however they like: "Vivaldi: The Four Seasons" in the album and
  # the opus number in the title, or all of it in one.
  defp text_of(%Track{} = track), do: "#{track.title} #{track.album}"

  # The source's credit appearing anywhere in the candidate. Not a similarity —
  # a substring — because "Vivaldi" inside "Vivaldi: The Four Seasons" is the
  # whole point and scores poorly as a string comparison.
  defp composer_present?(%Track{artists: []}, _candidate), do: false

  defp composer_present?(%Track{} = source, %Track{} = candidate) do
    haystack = fold("#{candidate.title} #{candidate.album} #{Enum.join(candidate.artists, " ")}")

    Enum.any?(source.artists, fn artist ->
      case surname(artist) do
        "" -> false
        name -> String.contains?(haystack, name)
      end
    end)
  end

  # The last word of the credit. "Johann Sebastian Bach" is credited as "Bach"
  # by every catalogue that abbreviates, and as the full name by the rest; the
  # surname is the part they agree on.
  defp surname(artist) when is_binary(artist) do
    artist
    |> fold()
    |> String.replace(",", " ")
    |> String.split(~r/\s+/, trim: true)
    |> List.last()
    |> Kernel.||("")
  end

  defp surname(_artist), do: ""

  # Where in the band. Every candidate reaching here already agrees on the work
  # and the movement, so this only chooses between recordings of it.
  defp placement(source_work, candidate_work) do
    @floor + (@ceiling - @floor) * Work.agreement(source_work, candidate_work)
  end

  defp evidence(source_work, candidate_work) do
    [
      work:
        source_work.catalogue |> MapSet.intersection(candidate_work.catalogue) |> MapSet.to_list(),
      form: source_work.form,
      movement: source_work.roman || source_work.tempo
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp fold(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end
end
