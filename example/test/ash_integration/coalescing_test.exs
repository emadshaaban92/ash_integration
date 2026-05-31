defmodule Example.AshIntegration.CoalescingTest do
  use Example.DataCase, async: true
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers

  # By default an integration only delivers the latest state per resource: when a new
  # event is dispatched, older PENDING events for the same (integration, resource_id)
  # are coalesced (cancelled). Opt out per integration with notify_on_every_change.

  defp run_all_dispatchers! do
    jobs =
      Oban.Job
      |> Ecto.Query.where(worker: "AshIntegration.Workers.EventDispatcher")
      |> Ecto.Query.where(state: "available")
      |> Ecto.Query.order_by(asc: :id)
      |> Example.Repo.all()

    Enum.each(jobs, fn job ->
      Oban.Testing.perform_job(AshIntegration.Workers.EventDispatcher, job.args,
        repo: Example.Repo
      )
    end)

    # perform_job/3 doesn't consume the persisted job, so delete the ones we ran to
    # avoid re-dispatching them on a subsequent run_all_dispatchers!/0 call.
    ids = Enum.map(jobs, & &1.id)
    Oban.Job |> Ecto.Query.where([j], j.id in ^ids) |> Example.Repo.delete_all()
  end

  defp update_product!(product, attrs) do
    product
    |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp by_state(events), do: Enum.group_by(events, & &1.state)

  describe "default (notify_on_every_change = false)" do
    test "keeps only the latest pending event per resource; supersedes the rest" do
      stub_webhook_success()
      integration = create_outbound_integration!(%{actions: ["create", "update"]})

      product = create_product!()
      product = update_product!(product, %{name: "v2"})
      _product = update_product!(product, %{name: "v3"})

      run_all_dispatchers!()

      events = get_events(integration.id)
      grouped = by_state(events)

      # 3 source changes (create, update, update) for the same resource → 1 survives.
      assert length(events) == 3
      assert length(grouped[:pending] || []) == 1
      assert length(grouped[:cancelled] || []) == 2

      # The survivor is the newest by occurred_at; the cancelled ones carry the reason.
      [survivor] = grouped[:pending]
      newest = Enum.max_by(events, & &1.occurred_at)
      assert survivor.id == newest.id

      for cancelled <- grouped[:cancelled] do
        assert cancelled.last_error == "Superseded by a newer update (coalesced)"
      end
    end

    test "coalesces per resource — different resources don't supersede each other" do
      stub_webhook_success()
      integration = create_outbound_integration!(%{actions: ["create", "update"]})

      product_a = create_product!()
      update_product!(product_a, %{name: "a2"})

      product_b = create_product!()
      update_product!(product_b, %{name: "b2"})

      run_all_dispatchers!()

      events = get_events(integration.id)
      pending = Enum.filter(events, &(&1.state == :pending))

      # One survivor per distinct resource.
      assert length(pending) == 2
      assert Enum.map(pending, & &1.resource_id) |> Enum.sort() ==
               Enum.sort([product_a.id, product_b.id])
    end

    test "never cancels a scheduled (in-flight) event" do
      stub_webhook_success()
      integration = create_outbound_integration!(%{actions: ["create", "update"]})

      product = create_product!()
      run_all_dispatchers!()

      # Schedule the first event (now :scheduled, with a delivery job).
      schedule_via_real_scheduler()
      [scheduled] = Enum.filter(get_events(integration.id), &(&1.state == :scheduled))

      # A newer update arrives and is dispatched.
      update_product!(product, %{name: "v2"})
      run_all_dispatchers!()

      events = get_events(integration.id)
      grouped = by_state(events)

      # The scheduled event is untouched; the new update is a fresh pending. Nothing cancelled.
      assert length(grouped[:scheduled] || []) == 1
      assert hd(grouped[:scheduled]).id == scheduled.id
      assert length(grouped[:pending] || []) == 1
      assert grouped[:cancelled] == nil
    end

    test "does not coalesce when a pending event has no payload (broken chain)" do
      # A broken Lua script yields nil-payload :pending events. Coalescing must skip so it
      # never strands the chain by cancelling deliverable siblings — the chain stays intact
      # until :reprocess.
      stub_webhook_success()

      integration =
        create_outbound_integration!(%{actions: ["create", "update"], transform_script: "result = {"})

      product = create_product!()
      update_product!(product, %{name: "v2"})

      run_all_dispatchers!()

      events = get_events(integration.id)
      pending = Enum.filter(events, &(&1.state == :pending))

      assert length(pending) == 2
      assert Enum.all?(pending, &is_nil(&1.payload))
      assert Enum.filter(events, &(&1.state == :cancelled)) == []
    end
  end

  describe "notify_on_every_change = true (opt out)" do
    test "keeps every update — no coalescing" do
      stub_webhook_success()

      integration =
        create_outbound_integration!(%{
          actions: ["create", "update"],
          notify_on_every_change: true
        })

      product = create_product!()
      product = update_product!(product, %{name: "v2"})
      _product = update_product!(product, %{name: "v3"})

      run_all_dispatchers!()

      events = get_events(integration.id)
      pending = Enum.filter(events, &(&1.state == :pending))

      assert length(events) == 3
      assert length(pending) == 3
      assert Enum.filter(events, &(&1.state == :cancelled)) == []
    end
  end
end
