defmodule Example.IntegrationHelpers do
  @moduledoc """
  Shared test helpers for the event-first outbound pipeline: creating an actor
  and stubbing HTTP delivery through `Req.Test`.
  """

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

  def stub_webhook_success do
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ok"}))
    end)
  end

  def stub_webhook_failure(status \\ 500) do
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{error: "server error"}))
    end)
  end

  def stub_webhook_capture(test_pid) do
    Req.Test.stub(AshIntegration.Outbound.Wire.Transports.Http, fn conn ->
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
end
