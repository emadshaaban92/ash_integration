defmodule AshIntegration.Web.Outbound.DeliveryLive.Helpers do
  @moduledoc false
  # Shared rendering helpers for the EventDelivery (delivery state machine) views.
  use Phoenix.Component

  import AshIntegration.Web.Components, only: [icon: 1]

  @doc "A parked delivery: build-failed, awaiting `reprocess`, with no cached body."
  def parked?(%{state: :parked}), do: true
  def parked?(_), do: false

  attr :delivery, :map, required: true

  @doc "Delivery-state badge; a parked delivery is called out separately from a healthy one."
  def state_badge(assigns) do
    ~H"""
    <span :if={parked?(@delivery)} class="badge badge-sm badge-error gap-1">
      <.icon name="hero-exclamation-triangle-mini" class="size-3" /> Parked
    </span>
    <span :if={!parked?(@delivery)} class={["badge badge-sm", state_class(@delivery.state)]}>
      {state_label(@delivery.state)}
    </span>
    """
  end

  defp state_class(:delivered), do: "badge-success"
  defp state_class(:scheduled), do: "badge-info"
  defp state_class(:pending), do: "badge-warning"
  defp state_class(:parked), do: "badge-error"
  defp state_class(:cancelled), do: "badge-ghost"
  defp state_class(_), do: "badge-ghost"

  defp state_label(state), do: state |> to_string() |> String.capitalize()
end
