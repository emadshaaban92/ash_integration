defmodule Example.IntegrationHelpers do
  @moduledoc """
  Test helpers for creating outbound integrations and stubbing HTTP delivery.
  """

  alias Example.Integration.OutboundIntegration
  alias Example.Integration.DeliveryLog

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

  def create_outbound_integration!(attrs \\ %{}) do
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

  def get_delivery_logs(outbound_integration_id) do
    DeliveryLog
    |> Ash.Query.filter(outbound_integration_id == ^outbound_integration_id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  def reload_integration!(integration) do
    Ash.get!(OutboundIntegration, integration.id, authorize?: false)
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

  def execute_pipeline!(_product) do
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

    # Fetch the real delivery job from DB (inserted by EventDispatcher)
    # and execute it directly so the ordering check works correctly
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

    {dispatcher_job, delivery_jobs, results}
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
