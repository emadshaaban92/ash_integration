defmodule AshIntegration.Inbound.Execute.Relay do
  @moduledoc """
  The command **relay**: a Broadway pipeline that claims claimable `:pending`
  `CommandExecution` rows and executes each through `Inbound.Execute.execute/2`.

      Producer (claim WHERE state = 'pending', SKIP LOCKED + lease)
        → Processors  (execute/2: build → apply+finalize (fenced txn) → classify)
        → ack (no-op: the outcome is already committed on the row)

  It drives response-transport rows (created unclaimed by the delivery
  transaction) and is the **universal crash-recovery sweep** for any stale
  `:pending` row regardless of transport — push transports execute inline, but a
  consumer that died mid-apply leaves a leased `:pending` row the relay re-claims.

  Execution correctness rests on the `claimed_at` fence, not on claim order, so
  the relay runs one pipeline per node (each claims via `SKIP LOCKED`), no leader
  election, no job queue — the `CommandExecution` table is the durable record and
  the relay claims it directly.

  Configuration is owned and validated by
  `AshIntegration.Inbound.Execute.Supervisor`, which passes the in-tree knobs
  (`concurrency`, `poll_interval_ms`, `batch_size`) down to `start_link/1`; this
  module never reads `Application.get_env`.
  """
  use Broadway

  require Logger

  alias AshIntegration.Inbound.Execute
  alias AshIntegration.Inbound.Execute.RelayProducer
  alias AshIntegration.Inbound.Execute.Supervisor, as: Stage
  alias Broadway.Message

  @doc """
  Start the relay. Accepts `:name` (defaults to `__MODULE__`) plus the command
  tuning knobs; any omitted knob is filled from the stage schema, so tests run
  isolated instances via `start_supervised!({Relay, name: unique})`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    config = Stage.validate!(opts)

    Broadway.start_link(__MODULE__,
      name: name,
      producer: [
        module:
          {RelayProducer,
           poll_interval_ms: config[:poll_interval_ms], claim_limit: config[:batch_size]},
        concurrency: 1
      ],
      processors: [default: [concurrency: config[:concurrency]]]
    )
  end

  @impl true
  def handle_message(_processor, %Message{data: row} = message, _context) do
    Execute.execute(row)
    message
  rescue
    e ->
      # The row's outcome write is owned by `execute/2`; a raise here is unexpected
      # (e.g. a crash between claim and finalize). Leave the row `:pending` — the
      # lease expires and a later poll re-claims it. Fail the message so Broadway
      # records it; never let one row tear down the pipeline.
      Logger.error(
        "Inbound command relay: execute/2 raised for #{row.id}: #{Exception.message(e)}"
      )

      Message.failed(message, "execute raised: #{Exception.message(e)}")
  end
end
