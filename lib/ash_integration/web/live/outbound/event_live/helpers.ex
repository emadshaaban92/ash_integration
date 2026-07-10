defmodule AshIntegration.Web.Outbound.EventLive.Helpers do
  @moduledoc false
  # Rendering helpers for the immutable Event (fact / outbox) views.
  use Phoenix.Component

  import AshIntegration.Web.Components, only: [icon: 1]

  @doc """
  Outbox lifecycle of a fact: dispatched, still in the outbox, or stuck/terminal.
  A fact is stuck when it is undispatched and terminal (`dispatch_terminal_reason`
  set — the opt-in age sweep gave up on it). There is no attempt ceiling.
  """
  def stuck?(%{dispatched_at: nil, dispatch_terminal_reason: reason}) when not is_nil(reason),
    do: true

  def stuck?(_event), do: false

  def dispatched?(%{dispatched_at: nil}), do: false
  def dispatched?(_event), do: true

  attr :event, :map, required: true

  def outbox_badge(assigns) do
    ~H"""
    <span :if={stuck?(@event)} class="badge badge-sm badge-error gap-1">
      <.icon name="hero-exclamation-triangle-mini" class="size-3" />
      Stuck ({@event.dispatch_terminal_reason})
    </span>
    <span :if={!stuck?(@event) and dispatched?(@event)} class="badge badge-sm badge-success">
      Dispatched
    </span>
    <span :if={!stuck?(@event) and !dispatched?(@event)} class="badge badge-sm badge-warning">
      In outbox
    </span>
    """
  end
end
