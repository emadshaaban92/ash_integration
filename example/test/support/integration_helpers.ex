defmodule Example.IntegrationHelpers do
  @moduledoc """
  Test helpers for creating outbound integrations and stubbing HTTP delivery.
  """

  alias Example.Integration.OutboundIntegration

  require Ash.Query

  # Used by execute_pipeline!/1 for Oban.Job queries
  import Ecto.Query, warn: false

  def create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "test-#{System.unique_integer([:positive])}@example.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end

  def deactivate_seed_integrations! do
    AshIntegration.outbound_integration_resource()
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn integration ->
      Ash.update!(integration, %{}, action: :deactivate, authorize?: false)
    end)
  end

  def create_outbound_integration!(attrs \\ %{}) do
    deactivate_seed_integrations!()
    owner = create_user!()

    defaults = %{
      name: "test-integration-#{System.unique_integer([:positive])}",
      resource: "product",
      actions: ["create"],
      schema_version: 1,
      transport_config: %{
        type: :http,
        url: "http://localhost:9999/webhook",
        auth: %{type: "none"},
        timeout_ms: 5000
      },
      transform_script: "result = event",
      owner_id: owner.id
    }

    attrs = Map.merge(defaults, attrs)

    OutboundIntegration
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  def get_outbound_integration_logs(outbound_integration_id) do
    AshIntegration.outbound_integration_log_resource()
    |> Ash.Query.filter(outbound_integration_id == ^outbound_integration_id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  def get_events(outbound_integration_id) do
    AshIntegration.outbound_integration_event_resource()
    |> Ash.Query.filter(outbound_integration_id == ^outbound_integration_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  def reload_integration!(integration) do
    Ash.get!(OutboundIntegration, integration.id, authorize?: false)
  end

  def reload_event!(event) do
    Ash.get!(AshIntegration.outbound_integration_event_resource(), event.id, authorize?: false)
  end

  def stub_webhook_success do
    Req.Test.stub(AshIntegration.Workers.OutboundDelivery, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ok"}))
    end)
  end

  def stub_webhook_failure(status \\ 500) do
    Req.Test.stub(AshIntegration.Workers.OutboundDelivery, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{error: "server error"}))
    end)
  end

  def stub_webhook_capture(test_pid) do
    Req.Test.stub(AshIntegration.Workers.OutboundDelivery, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:webhook_request,
         %{
           method: conn.method,
           path: conn.request_path,
           headers: conn.req_headers,
           body: body
         }}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ok"}))
    end)
  end

  @doc """
  Runs the full pipeline: EventDispatcher → EventScheduler → OutboundDelivery.

  Returns `{dispatcher_job, events, delivery_results}` where:
  - `dispatcher_job` is the Oban job that was executed
  - `events` is the list of OutboundIntegrationEvent records created
  - `delivery_results` is the list of results from executing delivery jobs
  """
  def run_latest_dispatcher! do
    [dispatcher_job] =
      Oban.Job
      |> Ecto.Query.where(worker: "AshIntegration.Workers.EventDispatcher")
      |> Ecto.Query.where(state: "available")
      |> Ecto.Query.order_by(desc: :id)
      |> Ecto.Query.limit(1)
      |> Example.Repo.all()

    Oban.Testing.perform_job(
      AshIntegration.Workers.EventDispatcher,
      dispatcher_job.args,
      repo: Example.Repo
    )
  end

  def execute_pipeline!(_product) do
    # Step 1: Run only the LATEST EventDispatcher job (from this test, not seed data)
    [dispatcher_job] =
      Oban.Job
      |> Ecto.Query.where(worker: "AshIntegration.Workers.EventDispatcher")
      |> Ecto.Query.where(state: "available")
      |> Ecto.Query.order_by(desc: :id)
      |> Ecto.Query.limit(1)
      |> Example.Repo.all()

    Oban.Testing.perform_job(
      AshIntegration.Workers.EventDispatcher,
      dispatcher_job.args,
      repo: Example.Repo
    )

    # Step 2: Use the real EventScheduler scheduling logic —
    # find_ready_pairs + schedule oldest pending event per pair.
    # This exercises the production code path including suspension
    # filtering, nil-payload blocking, and oldest-first selection.
    schedule_via_real_scheduler()

    # Step 3: Get the events that were scheduled
    events =
      AshIntegration.outbound_integration_event_resource()
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(authorize?: false)

    # Step 4: Execute ALL delivery jobs
    delivery_jobs =
      Oban.Job
      |> Ecto.Query.where(worker: "AshIntegration.Workers.OutboundDelivery")
      |> Ecto.Query.where(state: "available")
      |> Ecto.Query.order_by(asc: :id)
      |> Example.Repo.all()

    results =
      Enum.map(delivery_jobs, fn job ->
        AshIntegration.Workers.OutboundDelivery.perform(job)
      end)

    {dispatcher_job, events, results}
  end

  @doc """
  Exercises the real EventScheduler scheduling logic: find_ready_pairs,
  then for each pair query the oldest pending event and schedule it if
  it has a payload. This is the production code path.
  """
  def schedule_via_real_scheduler do
    event_resource = AshIntegration.outbound_integration_event_resource()
    ready_pairs = AshIntegration.EventScheduler.find_ready_pairs(100)

    for {integration_id, resource_id} <- ready_pairs do
      case event_resource
           |> Ash.Query.for_read(:next_pending, %{
             outbound_integration_id: integration_id,
             resource_id: resource_id
           })
           |> Ash.read(authorize?: false) do
        {:ok, [event | _]} ->
          if event.payload do
            event
            |> Ash.Changeset.for_update(:schedule, %{}, authorize?: false)
            |> Ash.update(authorize?: false)
          end

        _ ->
          :ok
      end
    end
  end

  def create_product!(attrs \\ %{}) do
    defaults = %{
      name: "Test Product #{System.unique_integer([:positive])}",
      sku: "SKU-#{System.unique_integer([:positive])}"
    }

    attrs = Map.merge(defaults, attrs)

    Example.Catalog.Product
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
