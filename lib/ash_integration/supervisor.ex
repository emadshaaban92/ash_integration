defmodule AshIntegration.Supervisor do
  @moduledoc """
  Top-level supervisor for AshIntegration runtime processes.

  Add this to your application's supervision tree:

      children = [
        # ... your other children ...
        AshIntegration.Supervisor
      ]
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if AshIntegration.enabled?() do
      # Boot verifier: reject cross-mention event-schema conflicts at startup
      # rather than lazily at first dispatch. One scan of the source_domains.
      AshIntegration.Outbound.Declare.Registry.verify!()

      children = [
        AshIntegration.Transport.KafkaClientManager,
        # The scheduler (brain): promotes pending → scheduled, owning ordering
        # (lane-head selection, the high-water gate #57, suspension).
        AshIntegration.Outbound.Delivery.Scheduler,
        # The dispatch stage: owns + validates its config (NimbleOptions) and
        # supervises the Broadway outbox relay that claims undispatched Events and
        # fans them out into EventDelivery rows. The scheduler high-water gate
        # (#57) keeps ordering correct, so running one pipeline per node is safe.
        AshIntegration.Outbound.Dispatch.Supervisor,
        # The delivery stage (muscle): owns + validates its config and supervises
        # the Broadway relay that claims `:scheduled` EventDelivery rows and executes
        # them over their transport. Replaces the per-delivery Oban job + the
        # DeliveryGuardian — a lost/crashed claim just lets the soft lease expire and
        # another pass re-claims (idempotent), the same model as the dispatch relay.
        AshIntegration.Outbound.Delivery.Supervisor,
        # Retention stage: an autovacuum-style GenServer that owns + validates its
        # config and trims aged Event / EventDelivery / Log rows in bounded passes.
        AshIntegration.Outbound.Retention,
        # Data-drift check: warn (never crash) about subscriptions whose event
        # type/version left the catalog. Runs once, off the boot path (it touches
        # the DB), and is allowed to finish and stay down.
        Supervisor.child_spec(
          {Task, &AshIntegration.Outbound.Declare.Registry.warn_orphaned_subscriptions/0},
          id: :ash_integration_subscription_boot_check,
          restart: :temporary
        )
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      :ignore
    end
  end
end
