defmodule AshIntegration do
  @moduledoc """
  Spark DSL extension for integration-oriented Ash resource metadata.

  The initial surface is the `outbound_integrations` section, which declares
  which resource actions can be published to outbound integrations and which
  loader module owns their payload generation.

  ## Configuration

      config :ash_integration,
        otp_app: :my_app,
        outbound_integration_resource: MyApp.Integration.OutboundIntegration,
        delivery_log_resource: MyApp.Integration.DeliveryLog,
        domain: MyApp.Integration,
        repo: MyApp.Repo,
        actor_resource: MyApp.Accounts.User,
        vault: MyApp.Vault

  """

  def config, do: Application.get_all_env(:ash_integration)

  def otp_app do
    Keyword.fetch!(config(), :otp_app)
  end

  def outbound_integration_resource do
    Keyword.fetch!(config(), :outbound_integration_resource)
  end

  def delivery_log_resource do
    Keyword.fetch!(config(), :delivery_log_resource)
  end

  def domain do
    Keyword.fetch!(config(), :domain)
  end

  def repo do
    Keyword.fetch!(config(), :repo)
  end

  def actor_resource do
    Keyword.fetch!(config(), :actor_resource)
  end

  def vault do
    Keyword.fetch!(config(), :vault)
  end

  def auto_deactivation_threshold do
    Keyword.get(config(), :auto_deactivation_threshold, 50)
  end

  def delivery_log_retention_days do
    Keyword.get(config(), :delivery_log_retention_days, 90)
  end

  @outbound_action %Spark.Dsl.Entity{
    name: :outbound_action,
    describe: "Declares an action that can trigger outbound integrations.",
    target: AshIntegration.OutboundIntegrations.Action,
    args: [:name],
    identifier: :name,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The Ash action name exposed to outbound integrations."
      ]
    ]
  }

  @outbound_integrations %Spark.Dsl.Section{
    name: :outbound_integrations,
    describe: "Declare outbound integration metadata for an Ash resource.",
    schema: [
      resource_identifier: [
        type: :string,
        required: true,
        doc: "Stable external identifier used by outbound integrations."
      ],
      loader: [
        type: :atom,
        required: true,
        doc: "Loader module that builds outbound payloads for this resource."
      ],
      supported_versions: [
        type: {:wrap_list, :integer},
        required: true,
        doc: "Schema versions supported for this resource's outbound payload."
      ]
    ],
    entities: [@outbound_action]
  }

  use Spark.Dsl.Extension,
    sections: [@outbound_integrations],
    transformers: [AshIntegration.Transformer]
end
