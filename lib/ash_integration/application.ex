defmodule AshIntegration.Application do
  @moduledoc false
  # Minimal always-on OTP application for the library. It starts ONLY the
  # `Task.Supervisor` that isolates untrusted Lua transform execution
  # (`AshIntegration.Outbound.Delivery.Transform.Runtime.Lua`) from its caller.
  #
  # This is deliberately independent of the runtime pipeline `enabled?` switch and
  # of `AshIntegration.Supervisor`: a transform can be run from delivery, dispatch,
  # the dashboard preview, or a test — all of which must get sandbox isolation even
  # when the host composes the stage supervisors itself or keeps the runtime off.
  #
  # The OAuth2 token cache lives here too (not in the runtime `Supervisor`): the
  # HTTP transport is always available and can carry an OAuth2 client-credentials
  # auth, so its token cache must be up whenever a transport runs — including
  # dashboard previews and tests that exercise auth directly. It is lightweight (an
  # ETS table + an idle GenServer), so keeping it always-on is cheap.
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: AshIntegration.TaskSupervisor},
      AshIntegration.Transport.OAuth2.TokenCache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshIntegration.AppSupervisor)
  end
end
