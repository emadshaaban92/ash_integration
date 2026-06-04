defmodule AshIntegration.Web.Outbound.EventLive.Helpers do
  @moduledoc false
  # Rendering helpers for the immutable Event (fact / outbox) views.
  use Phoenix.Component

  import AshIntegration.Web.Components, only: [icon: 1]

  @doc "Outbox lifecycle of a fact: dispatched, still in the outbox, or stuck/poison."
  def stuck?(%{dispatched_at: nil, dispatch_attempts: n}, max) when is_integer(n),
    do: n >= max

  def stuck?(_event, _max), do: false

  def dispatched?(%{dispatched_at: nil}), do: false
  def dispatched?(_event), do: true

  attr :event, :map, required: true
  attr :max_attempts, :integer, required: true

  def outbox_badge(assigns) do
    ~H"""
    <span :if={stuck?(@event, @max_attempts)} class="badge badge-sm badge-error gap-1">
      <.icon name="hero-exclamation-triangle-mini" class="size-3" /> Stuck
    </span>
    <span
      :if={!stuck?(@event, @max_attempts) and dispatched?(@event)}
      class="badge badge-sm badge-success"
    >
      Dispatched
    </span>
    <span
      :if={!stuck?(@event, @max_attempts) and !dispatched?(@event)}
      class="badge badge-sm badge-warning"
    >
      In outbox
    </span>
    """
  end
end
