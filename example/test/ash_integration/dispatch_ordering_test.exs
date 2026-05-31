defmodule Example.AshIntegration.DispatchOrderingTest do
  @moduledoc """
  Delivery ordering, and what a `notify_on_every_change` consumer receives.

  The dispatch queue runs concurrently, so EventDispatcher jobs for the same
  resource can be processed out of order. These tests pin down that this never
  leaves a consumer on a stale final state, and document that each delivery
  carries the resource's state as snapshotted at dispatch time.
  """
  use Example.DataCase, async: true
  use Oban.Testing, repo: Example.Repo

  import Example.IntegrationHelpers

  defp update_product!(product, attrs) do
    product
    |> Ash.Changeset.for_update(:update, attrs, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp dispatcher_jobs do
    Oban.Job
    |> Ecto.Query.where(worker: "AshIntegration.Workers.EventDispatcher")
    |> Ecto.Query.where(state: "available")
    |> Ecto.Query.order_by(asc: :id)
    |> Example.Repo.all()
  end

  defp run_dispatcher!(job) do
    Oban.Testing.perform_job(AshIntegration.Workers.EventDispatcher, job.args, repo: Example.Repo)
    Example.Repo.delete!(job)
  end

  # Drain the pipeline (schedule oldest pending per resource, deliver, repeat) until
  # empty, so deliveries are observed in the scheduler's real order.
  defp drain_deliveries! do
    schedule_via_real_scheduler()

    jobs =
      Oban.Job
      |> Ecto.Query.where(worker: "AshIntegration.Workers.OutboundDelivery")
      |> Ecto.Query.where(state: "available")
      |> Ecto.Query.order_by(asc: :id)
      |> Example.Repo.all()

    case jobs do
      [] ->
        :ok

      _ ->
        Enum.each(jobs, fn job ->
          AshIntegration.Workers.OutboundDelivery.perform(job)
          Example.Repo.delete!(job)
        end)

        drain_deliveries!()
    end
  end

  # Names delivered to the stubbed webhook, in delivery order.
  defp delivered_names do
    collect([]) |> Enum.reverse()
  end

  defp collect(acc) do
    receive do
      {:webhook_request, %{body: body}} ->
        collect([body |> Jason.decode!() |> get_in(["data", "name"]) | acc])
    after
      0 -> acc
    end
  end

  describe "final state under out-of-order dispatch" do
    test "deliveries follow dispatch order and end on the current state" do
      # State proxy: the product name moves "active" -> "inactive".
      stub_webhook_capture(self())

      create_outbound_integration!(%{actions: ["create", "update"], notify_on_every_change: true})

      # Dispatch the create while the product is still "active", so its event captures
      # the "active" snapshot and gets the smaller event id.
      product = create_product!(%{name: "active"})
      [create_job] = dispatcher_jobs()
      run_dispatcher!(create_job)

      # Then the "deactivate": update to "inactive", dispatched after (larger id).
      update_product!(product, %{name: "inactive"})
      [update_job] = dispatcher_jobs()
      run_dispatcher!(update_job)

      drain_deliveries!()

      # Delivery follows event id (dispatch order): "active" first, "inactive" last.
      assert delivered_names() == ["active", "inactive"]
    end

    test "reversed dispatch still ends on the current state" do
      stub_webhook_capture(self())

      create_outbound_integration!(%{actions: ["create", "update"], notify_on_every_change: true})

      # Apply both changes first, then dispatch the later change before the earlier one.
      product = create_product!(%{name: "active"})
      update_product!(product, %{name: "inactive"})

      [create_job, update_job] = dispatcher_jobs()
      run_dispatcher!(update_job)
      run_dispatcher!(create_job)

      drain_deliveries!()

      # Both dispatchers ran after the product was already "inactive", so both events
      # captured "inactive" — the consumer cannot be left "active".
      names = delivered_names()
      assert Enum.all?(names, &(&1 == "inactive"))
      assert List.last(names) == "inactive"
    end
  end

  describe "notify_on_every_change payloads" do
    test "delivers one notification per change, each carrying the state at dispatch time" do
      # Payloads are snapshotted at dispatch time, not at the moment of each change. When
      # both changes are dispatched after both are applied, both deliveries carry the
      # state current at dispatch ("v2") — the consumer gets a notification per change,
      # not a replay of every historical value.
      stub_webhook_capture(self())

      create_outbound_integration!(%{actions: ["create", "update"], notify_on_every_change: true})

      product = create_product!(%{name: "v1"})
      update_product!(product, %{name: "v2"})

      Enum.each(dispatcher_jobs(), &run_dispatcher!/1)
      drain_deliveries!()

      names = delivered_names()

      # One delivery per change (2), each carrying the state at dispatch time ("v2").
      assert names == ["v2", "v2"]
    end
  end
end
