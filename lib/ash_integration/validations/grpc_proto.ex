defmodule AshIntegration.Validations.GrpcProto do
  @moduledoc """
  Validates that a gRPC config's proto_definition, service, and method are consistent.

  At config save time, parses the proto via `protoc` and verifies:
  1. No `import` statements (self-contained only)
  2. The proto is syntactically valid
  3. The specified service exists
  4. The specified method exists on that service
  5. The input message type can be resolved
  """
  use Ash.Resource.Validation

  alias AshIntegration.Transports.Grpc.ProtoRegistry

  @impl true
  def validate(changeset, _opts, _context) do
    proto = Ash.Changeset.get_attribute(changeset, :proto_definition)
    service = Ash.Changeset.get_attribute(changeset, :service)
    method = Ash.Changeset.get_attribute(changeset, :method)

    if is_nil(proto) || is_nil(service) || is_nil(method) do
      :ok
    else
      do_validate(proto, service, method)
    end
  end

  defp do_validate(proto, service, method) do
    # Use a fixed key since this is validation-time only (not cached per integration)
    with {:ok, descriptor_set} <- ProtoRegistry.get_or_parse("_validation", proto),
         {:ok, _input_ctx} <- ProtoRegistry.resolve_input_type(descriptor_set, service, method) do
      :ok
    else
      {:error, message} ->
        {:error, field: :proto_definition, message: message}
    end
  end
end
