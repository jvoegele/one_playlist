defmodule OnePlaylist.Library.EnrichmentSweeper do
  @moduledoc """
  The nightly job that queues recordings for enrichment.

  `OnePlaylist.Library.find_or_create/1` enqueues each recording as it arrives,
  which covers everything from now on. This covers the other two cases:

    * **Backfill.** Recordings stored before enrichment existed, and any whose
      job was cancelled or discarded.
    * **Re-asking.** MusicBrainz is edited continuously, so a recording it could
      not identify last month may be identifiable today —
      `OnePlaylist.Library.Enrichment.due/1` offers anything looked at more than
      thirty days ago, never-asked first.

  ## Oban Cron rather than pg_cron

  The four scheduled jobs this application already has run in `pg_cron`, and the
  standing preference is the Supabase-native one. Not here: pg_cron's jobs are
  all *deletions expressed in SQL*, which is work Postgres can finish by itself.
  This one only decides which rows to hand to an Elixir worker, so scheduling it
  in Postgres would mean writing Oban's job rows by hand from SQL — reaching
  into another library's table to avoid using that library's own scheduler.

  Same reasoning in the other direction as the pruning jobs, and the rule from
  `CLAUDE.md` holds either way: one scheduler per workload, never both.

  ## The batch is a budget, not a page

  `@batch` recordings a night, because that is what one request a second can
  actually get through — up to two requests each, so a full batch is roughly
  twenty minutes of queue time. A larger number would not enrich anything
  sooner; it would only pile up jobs that the next night's sweep would have
  enqueued anyway, and `unique` would then reject.

  A backlog therefore drains over several nights, oldest first, which is the
  right order and is why nothing here reports "N remaining" as a problem.
  """

  use Oban.Worker, queue: :enrichment, max_attempts: 1

  alias OnePlaylist.Library.Enrichment
  alias OnePlaylist.Library.EnrichmentWorker

  require Logger

  @batch 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    due = Enrichment.due(@batch)

    Enum.each(due, &EnrichmentWorker.enqueue(&1.id))

    Logger.info("queued #{length(due)} recording(s) for enrichment")

    :ok
  end
end
