defmodule AshIntegration.Application do
  @moduledoc false
  # Minimal always-on OTP application for the library. It starts ONLY the
  # `Task.Supervisor` that isolates untrusted Lua transform execution
  # (`AshIntegration.Outbound.Delivery.LuaSandbox`) from its caller.
  #
  # This is deliberately independent of the runtime pipeline `enabled?` switch and
  # of `AshIntegration.Supervisor`: a transform can be run from delivery, dispatch,
  # the dashboard preview, or a test — all of which must get sandbox isolation even
  # when the host composes the stage supervisors itself or keeps the runtime off.
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: AshIntegration.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshIntegration.AppSupervisor)
  end
end
