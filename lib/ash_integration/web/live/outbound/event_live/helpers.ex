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
  # The list view projects a lean column set; a dropped field comes back as
  # `%Ash.NotLoaded{}`, which does NOT match the `nil` head below and would fall
  # through the catch-all to a silently-wrong badge. Fail loud instead so a missing
  # field in the list view's `@list_fields` surfaces immediately, not as bad data.
  def stuck?(%{dispatched_at: %Ash.NotLoaded{}}), do: unloaded!(:dispatched_at)

  def stuck?(%{dispatch_terminal_reason: %Ash.NotLoaded{}}),
    do: unloaded!(:dispatch_terminal_reason)

  def stuck?(%{dispatched_at: nil, dispatch_terminal_reason: reason}) when not is_nil(reason),
    do: true

  def stuck?(_event), do: false

  def dispatched?(%{dispatched_at: %Ash.NotLoaded{}}), do: unloaded!(:dispatched_at)
  def dispatched?(%{dispatched_at: nil}), do: false
  def dispatched?(_event), do: true

  defp unloaded!(field) do
    raise ArgumentError,
          "EventLive outbox badge needs `#{field}`, but it was not selected. " <>
            "Add it to `@list_fields` in the list view before rendering the badge."
  end

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
