defmodule AshIntegration.Outbound.Retention do
  @moduledoc """
  Root of the **retention stage** and the owner of its configuration.

  Trims the event-first tables autovacuum-style: frequent passes, each deleting at
  most `delete_limit` rows per table (oldest first), so a backlog drains over
  successive passes instead of one large delete. Runs in the library's own
  supervision tree — no host Oban cron/queue to wire.

  Three tables, two windows:

    * `EventDelivery` and `Log` — terminal/aged rows older than the (shorter)
      `delivery_days` window;
    * the immutable `Event` (source of truth) — older than its own (longer)
      `event_days` window, and only once it has been **dispatched** and has **no
      remaining deliveries**, so retention never strands a delivery an operator
      still has to reprocess, and never reaps a stuck/poison event — which would
      silently unblock its `(connection, event_key)` lane (the
      `dispatched_at IS NOT NULL` guard).

  The "what is old enough to delete" policy lives here, not on the resources: they
  keep only a generic `:destroy`, while this module owns the filters and runs the
  deletes through Ash (`Ash.bulk_destroy`).

  ## Config — one nested key, owned by this stage

      config :ash_integration,
        retention: [
          interval_ms:   :timer.minutes(1),
          delete_limit:  500,
          delivery_days: 90,
          event_days:    365
        ]

  Whether this runs at all is the single `AshIntegration.enabled?/0` switch; there
  is no per-stage on/off.

  Like the dispatch stage, this GenServer validates its config slice in `init/1`
  via NimbleOptions (fail-fast at boot) and publishes the window/limit values to
  `:persistent_term`, so `sweep/0` — which is also called directly (tests, manual
  runs) without going through the GenServer — reads them with a fallback to the
  schema default when the sweeper isn't running.

  Note: with one sweeper per node a multi-node host runs N concurrent passes;
  delete-where-old is idempotent, so that is wasted work, not incorrectness.
  """
  use GenServer

  require Ash.Query
  require Logger

  @doc """
  The NimbleOptions schema for the retention stage. A function so runtime defaults
  (`:timer.minutes/1`) resolve on the runtime host.
  """
  def opts_schema do
    [
      interval_ms: [
        type: :pos_integer,
        default: :timer.minutes(1),
        doc: "Delay between passes. Short by design (autovacuum-style)."
      ],
      delete_limit: [
        type: :pos_integer,
        default: 500,
        doc:
          "Max rows deleted per table, per pass. Bounds each sweep so a large backlog drains over successive passes."
      ],
      delivery_days: [
        type: :pos_integer,
        default: 90,
        doc: "Retention window (days) for terminal EventDelivery + Log rows (the shorter window)."
      ],
      event_days: [
        type: :pos_integer,
        default: 365,
        doc:
          "Retention window (days) for the immutable Event log — the source of truth, kept independently of (and typically longer than) deliveries. Clamped up to delivery_days if set shorter."
      ]
    ]
  end

  @doc "Validate a `:retention` opts keyword against `opts_schema/0`. Raises on unknown keys / bad types."
  def validate!(opts), do: NimbleOptions.validate!(opts, opts_schema())

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one bounded retention pass, returning the per-table `Ash.BulkResult`. Driven
  by the periodic timer; also called directly in tests / manual runs.
  """
  def sweep(limit \\ delete_limit()) do
    delivery_days = delivery_days()
    event_days = event_window(delivery_days, event_days())
    now = DateTime.utc_now()

    # Sweep deliveries/logs (shorter window) before Events: an Event ages out only
    # once it has no remaining deliveries, so clearing terminal deliveries first
    # lets the matching Events become eligible in the same pass.
    %{
      delivery_log: bounded_delete(log_query(now, delivery_days), limit),
      event_delivery: bounded_delete(delivery_query(now, delivery_days), limit),
      event: bounded_delete(event_query(now, event_days), limit)
    }
  end

  @impl true
  def init(opts) do
    config = validate!(Keyword.merge(Application.get_env(:ash_integration, :retention, []), opts))

    # Publish the values read by `sweep/0` (which also runs outside this process)
    # for lock-free reads, with the guarded put so a restart with unchanged config
    # triggers no persistent_term global heap-scan.
    put_config(:delete_limit, config[:delete_limit])
    put_config(:delivery_days, config[:delivery_days])
    put_config(:event_days, config[:event_days])

    schedule(config[:interval_ms])
    {:ok, %{interval: config[:interval_ms]}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Never let a transient DB error crash-loop the sweeper; log and try next tick.
    try do
      sweep()
    rescue
      e -> Logger.error("AshIntegration retention sweep failed: #{Exception.message(e)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  # ── Config reads (persistent_term, schema-default fallback when not running) ──

  defp delete_limit, do: get_config(:delete_limit)
  defp delivery_days, do: get_config(:delivery_days)
  defp event_days, do: get_config(:event_days)

  defp get_config(key), do: :persistent_term.get({__MODULE__, key}, default(key))

  defp default(key), do: Keyword.fetch!(defaults(), key)

  defp defaults, do: validate!([])

  defp put_config(key, value) do
    pt_key = {__MODULE__, key}

    case :persistent_term.get(pt_key, :__unset__) do
      ^value -> :ok
      _ -> :persistent_term.put(pt_key, value)
    end
  end

  # ── Retention filters ───────────────────────────────────────────────────────

  defp delivery_query(now, days) do
    threshold = DateTime.add(now, -days, :day)

    AshIntegration.event_delivery_resource()
    |> Ash.Query.filter(
      state in [:delivered, :suppressed, :cancelled] and updated_at < ^threshold
    )
  end

  defp log_query(now, days) do
    threshold = DateTime.add(now, -days, :day)

    AshIntegration.delivery_log_resource()
    |> Ash.Query.filter(created_at < ^threshold)
  end

  defp event_query(now, days) do
    threshold = DateTime.add(now, -days, :day)

    AshIntegration.event_resource()
    |> Ash.Query.filter(
      created_at < ^threshold and not is_nil(dispatched_at) and not exists(deliveries, true)
    )
  end

  # ── Bounded delete via Ash ──────────────────────────────────────────────────

  # One bounded delete through the resource's generic `:destroy`. Ash + AshPostgres
  # compile the limited query into a single
  # `DELETE ... USING (SELECT id ... LIMIT n) WHERE id = ...` (verified against the
  # emitted SQL), so each pass caps at `limit` rows. Order is irrelevant: every
  # matching row is already past the window, so the eligible set shrinks
  # monotonically and drains over successive passes.
  defp bounded_delete(query, limit) do
    query = Ash.Query.limit(query, limit)

    with_query_log_level(fn ->
      Ash.bulk_destroy!(query, :destroy, %{}, authorize?: false, notify?: false)
    end)
  end

  # Honour `AshIntegration.query_log_level/0` for the per-sweep `DELETE` — the
  # retention equivalent of the poll-loop spam that knob was added for. The poll
  # loops pass Ecto's `:log` straight to `repo.query/3`; this delete runs through
  # Ash (`Ash.bulk_destroy!`), and AshPostgres threads no `:log` option down to
  # `repo.delete_all/2`, so there is no per-query hook to reach for here.
  #
  # Instead we scope *this* process's Logger level for the duration of the delete.
  # Ecto emits its query log synchronously in the calling process, and a process
  # level only ever raises the floor (the higher of process/primary level wins), so
  # this drops the `:debug` `DELETE` without un-silencing anything else. At `:debug`
  # (the default) logging is untouched; `false` silences the delete; any other level
  # acts as a floor — note that, unlike `repo.query/3`'s `:log`, a floor filters
  # rather than re-emits, so e.g. `:info` hides the `:debug` delete.
  defp with_query_log_level(fun) do
    case AshIntegration.query_log_level() do
      :debug -> fun.()
      level -> with_process_log_level(log_floor(level), fun)
    end
  end

  defp log_floor(false), do: :none
  defp log_floor(level), do: level

  defp with_process_log_level(level, fun) do
    previous = Logger.get_process_level(self())
    Logger.put_process_level(self(), level)

    try do
      fun.()
    after
      restore_process_log_level(previous)
    end
  end

  defp restore_process_log_level(nil), do: Logger.delete_process_level(self())
  defp restore_process_log_level(level), do: Logger.put_process_level(self(), level)

  # The Event window must be at least the delivery window (deliveries reference
  # their Event). A misconfiguration is operationally surprising, so warn + clamp.
  defp event_window(delivery_days, event_days) when event_days < delivery_days do
    Logger.warning(
      "AshIntegration retention: event_days (#{event_days}) is shorter than the delivery " <>
        "window (#{delivery_days}). Clamping the Event window to #{delivery_days} days; set " <>
        "retention: [event_days: …] >= delivery_days."
    )

    delivery_days
  end

  defp event_window(_delivery_days, event_days), do: event_days
end
