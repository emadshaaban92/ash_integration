defmodule AshIntegration.Web.Outbound.DeliveryLive.Helpers do
  @moduledoc false
  # Shared rendering helpers for the EventDelivery (delivery state machine) views.
  use Phoenix.Component

  import AshIntegration.Web.Components, only: [icon: 1]

  alias AshIntegration.Outbound.Delivery.ParkedHealth

  @doc "A parked delivery: build-failed, awaiting `reprocess`, with no cached body."
  def parked?(%{state: :parked}), do: true
  def parked?(_), do: false

  attr :record, :map,
    required: true,
    doc: "A Subscription/Connection with the :parked_count aggregate loaded."

  @doc """
  Standing parked-health badge for a Subscription/Connection. Renders nothing when
  the record is healthy (no parked backlog); a `Degraded (n)` / `Parked (n)` badge
  otherwise. Distinct from the per-delivery `state_badge/1` and from the
  transport/response `suspended` badge — parking is its own health dimension
  (`ParkedHealth`).

  The `:record` MUST have the `:parked_count` aggregate loaded — `ParkedHealth.status/1`
  raises (fail-loud) on an unloaded aggregate rather than silently reading healthy,
  so any new view rendering this badge has to load `[:parked_count]` first.
  """
  def health_badge(assigns) do
    status = ParkedHealth.status(assigns.record)
    assigns = assign(assigns, status: status, parked_count: assigns.record.parked_count)

    ~H"""
    <span
      :if={@status != :healthy}
      class={["badge badge-sm gap-1", health_class(@status)]}
      title="Parked deliveries — a broken transform/producer; reprocess to clear."
    >
      <.icon name="hero-exclamation-triangle-mini" class="size-3" />
      {health_label(@status)} ({@parked_count})
    </span>
    """
  end

  # Chronically parked is an error tier; a smaller backlog is a warning to watch.
  defp health_class(:parked), do: "badge-error"
  defp health_class(:degraded), do: "badge-warning"

  defp health_label(:parked), do: "Parked"
  defp health_label(:degraded), do: "Degraded"

  @doc "A terminal `:failed` delivery: never retried, blocking its lane (operator-only)."
  def terminal?(%{state: :failed, terminal_reason: reason}) when not is_nil(reason), do: true
  def terminal?(_), do: false

  attr :delivery, :map, required: true

  @doc """
  Delivery-state badge. Parked (build-failed) and terminal (`terminal_reason` set —
  lane blocked forever, operator-only recovery) deliveries are called out with their
  own error badges; a non-terminal `:failed` row is shown as `Retrying` (it is
  held-waiting on its backoff or probe, not dead).
  """
  def state_badge(assigns) do
    ~H"""
    <span :if={parked?(@delivery)} class="badge badge-sm badge-error gap-1">
      <.icon name="hero-exclamation-triangle-mini" class="size-3" /> Parked
    </span>
    <span
      :if={terminal?(@delivery)}
      class="badge badge-sm badge-error gap-1"
      title="Terminal — never retried; blocks its lane until an operator retries or cancels it."
    >
      <.icon name="hero-exclamation-triangle-mini" class="size-3" />
      Terminal ({@delivery.terminal_reason})
    </span>
    <span
      :if={!parked?(@delivery) and !terminal?(@delivery)}
      class={["badge badge-sm", state_class(@delivery.state)]}
      title={@delivery.state == :failed && "Failed — held on its lane, retried on backoff/probe."}
    >
      {state_label(@delivery.state)}
    </span>
    """
  end

  defp state_class(:delivered), do: "badge-success"
  defp state_class(:scheduled), do: "badge-info"
  defp state_class(:pending), do: "badge-warning"
  # A non-terminal `:failed` row is waiting-to-retry (backoff or probe-paced) — a
  # warning, not a dead end; the terminal case gets its own badge in state_badge/1.
  defp state_class(:failed), do: "badge-warning"
  # `:suppressed` is a deliberate, healthy no-send (content unchanged) — distinct
  # from `:delivered` (bytes sent) so it never reads as a real send, and distinct
  # from `:cancelled` (dropped/superseded). Neutral accent.
  defp state_class(:suppressed), do: "badge-neutral"
  # No `:parked` clause: parked deliveries get their own badge in state_badge/1,
  # so state_class/1 is only ever called for non-parked states.
  defp state_class(:cancelled), do: "badge-ghost"
  defp state_class(_), do: "badge-ghost"

  defp state_label(:failed), do: "Retrying"
  defp state_label(state), do: state |> to_string() |> String.capitalize()
end
