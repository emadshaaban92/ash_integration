defmodule AshIntegration.Web.Outbound.EventTypeLive.Index do
  @moduledoc false
  # The event-type catalog — the derived public contract. Not persisted: built
  # from the source resources' DSL at read time (`Registry.catalog/0`). This is
  # the front door of an event-first system — "here are the event types you
  # produce, their versions, and who produces them."
  use AshIntegration.Web, :live_view

  alias AshIntegration.Outbound.Declare.Registry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Event Types")
     |> assign(catalog: catalog_rows())
     |> assign(subscription_counts: subscription_counts(socket))}
  end

  # One cheap grouped read: event_type => count of subscriptions.
  defp subscription_counts(socket) do
    actor = socket.assigns.current_user

    case AshIntegration.subscription_resource()
         |> Ash.Query.for_read(:read, %{}, actor: actor)
         |> Ash.read(actor: actor, page: false) do
      {:ok, %{results: subs}} -> tally(subs)
      {:ok, subs} when is_list(subs) -> tally(subs)
      _ -> %{}
    end
  end

  defp tally(subs), do: Enum.frequencies_by(subs, & &1.event_type)

  defp catalog_rows do
    Registry.catalog()
    |> Enum.map(fn {type, %{versions: versions, producers: producers}} ->
      %{type: type, versions: versions, producers: Enum.uniq(producers)}
    end)
    |> Enum.sort_by(& &1.type)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 sm:p-6">
      <.outbound_nav active={:event_types} />

      <.page_header>
        Event Types
        <:subtitle>
          The derived contract — what your system produces. Declared in resource DSL.
        </:subtitle>
      </.page_header>

      <div :if={@catalog == []}>
        <.empty_state
          title="No event types declared yet"
          icon="hero-bolt"
        >
          <:actions>
            <p class="text-sm text-base-content/60 max-w-md">
              Declare event types with the <code>outbound_events</code>
              DSL on a source resource, and list its domain under <code>source_domains</code>.
            </p>
          </:actions>
        </.empty_state>
      </div>

      <table :if={@catalog != []} class="table table-zebra">
        <thead>
          <tr>
            <th>Event Type</th>
            <th>Versions</th>
            <th>Producers</th>
            <th>Subscriptions</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @catalog} id={"event-type-#{row.type}"}>
            <td class="font-medium font-mono text-sm">{row.type}</td>
            <td>
              <span :for={v <- row.versions} class="badge badge-sm badge-ghost mr-1">v{v}</span>
            </td>
            <td class="text-sm text-base-content/70">
              {length(row.producers)} {if length(row.producers) == 1,
                do: "producer",
                else: "producers"}
            </td>
            <td>
              <span class="badge badge-sm badge-info">
                {Map.get(@subscription_counts, row.type, 0)}
              </span>
            </td>
            <td class="text-right">
              <.link navigate={path(:show, row.type)} class="btn btn-ghost btn-xs">View</.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp path(:show, type), do: base() <> "/event-types/#{URI.encode(type)}"
  defp base, do: AshIntegration.Web.base_path()
end
