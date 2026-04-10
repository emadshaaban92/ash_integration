defmodule AshIntegration.GrpcConfig do
  @moduledoc """
  Embedded config for the **experimental** gRPC transport.

  See the [gRPC Transport guide](guides/grpc-transport.md) for details on
  the experimental status. Configuration options may change in future releases.
  """

  @vault Application.compile_env!(:ash_integration, :vault)

  use Ash.Resource,
    data_layer: :embedded,
    extensions: [AshCloak]

  cloak do
    vault @vault
    attributes [:signing_secret]
    decrypt_by_default []
  end

  attributes do
    attribute :endpoint, :string do
      allow_nil? false
      public? true
    end

    attribute :service, :string do
      allow_nil? false
      public? true
    end

    attribute :method, :string do
      allow_nil? false
      public? true
    end

    attribute :proto_definition, :string do
      allow_nil? false
      public? true
      constraints max_length: 102_400
    end

    attribute :timeout_ms, :integer do
      allow_nil? false
      public? true
      default 30_000
      constraints min: 1000
    end

    attribute :headers, :map do
      public? true
      default %{}
    end

    attribute :signing_secret, :string do
      public? true
      sensitive? true
    end

    attribute :security, :union do
      allow_nil? false
      public? true
      default %{type: "none"}

      constraints types: [
                    none: [
                      type: AshIntegration.GrpcSecurity.None,
                      tag: :type,
                      tag_value: "none"
                    ],
                    tls: [
                      type: AshIntegration.GrpcSecurity.Tls,
                      tag: :type,
                      tag_value: "tls"
                    ],
                    bearer_token: [
                      type: AshIntegration.GrpcSecurity.BearerToken,
                      tag: :type,
                      tag_value: "bearer_token"
                    ],
                    mutual_tls: [
                      type: AshIntegration.GrpcSecurity.MutualTls,
                      tag: :type,
                      tag_value: "mutual_tls"
                    ]
                  ],
                  storage: :map_with_tag
    end
  end

  validations do
    validate match(:endpoint, ~r/\A[a-zA-Z0-9._-]+(:\d+)?\z/),
      message: "must be a valid host:port"

    validate {AshIntegration.Validations.GrpcProto, []}
  end

  actions do
    default_accept :*
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
