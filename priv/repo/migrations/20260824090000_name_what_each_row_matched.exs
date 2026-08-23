defmodule OnePlaylist.Repo.Migrations.NameWhatEachRowMatched do
  @moduledoc """
  Say what a row matched *to*, and which album each side came from.

  A report row held the source track's title and artist, and for the
  destination only `destination_track_id` — an opaque provider id. So a matched
  row said "Corduroy · isrc · exact" and nothing about what it had actually
  chosen. The one question a person asks of a match is whether it is the right
  recording, and the row could not answer it.

  The album is the field that answers it. Three recordings of a song differ by
  release far more legibly than by title: *Vitalogy* against *Live On Two Legs*
  settles in one glance what a duration in seconds does not.

  These are denormalized on purpose. The alternative is asking the provider at
  render time for every row of a 5,000 track report, which is a rate-limited
  call per row to redisplay a decision already made. The candidate list stored
  beside them is denormalized for exactly the same reason.
  """

  use Ecto.Migration

  def change do
    alter table(:transfer_items) do
      add :source_album, :text

      # What was chosen, in the form a person reads. `destination_track_id`
      # stays the identity; these are the display.
      add :destination_title, :text
      add :destination_artist, :text
      add :destination_album, :text
    end
  end
end
