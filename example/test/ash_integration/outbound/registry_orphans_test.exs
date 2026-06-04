defmodule Example.Outbound.RegistryOrphansTest do
  @moduledoc """
  `Registry.warn_orphaned_subscriptions/1` streams the subscription table (rather
  than loading it whole) and rate-limits the per-orphan log so a misconfigured
  environment can't flood the boot log. Passing an EMPTY resource list yields an
  empty catalog, so every existing subscription is "orphaned" — a clean way to
  exercise the cap without bypassing the create-time event_type validation.
  """
  use Example.DataCase, async: false

  import ExUnit.CaptureLog

  alias AshIntegration.Outbound.Declare.Registry
  alias Example.Outbound.{Connection, Subscription}

  test "streams + caps the per-orphan logging and still returns every orphan" do
    owner = create_user!()
    # 21 = the @orphan_log_limit (20) + 1, so exactly one row spills into the summary.
    for _ <- 1..21, do: create_subscription!(create_connection!(owner))

    {orphans, log} =
      with_log(fn ->
        # Empty catalog (no resources) → every subscription is an orphan.
        Registry.warn_orphaned_subscriptions([])
      end)

    assert length(orphans) == 21

    individual_lines =
      log |> String.split("\n") |> Enum.count(&(&1 =~ "references unknown event"))

    assert individual_lines == 20
    assert log =~ "and 1 more orphaned subscription"
  end

  defp create_user! do
    Example.Accounts.User
    |> Ash.Changeset.for_create(
      :create,
      %{email: "t-#{System.unique_integer([:positive])}@x.com"},
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:hashed_password, Bcrypt.hash_pwd_salt("test1234"))
    |> Ash.create!(authorize?: false)
  end

  defp create_connection!(owner) do
    Connection
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "dest-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        transport_config: %{
          type: :http,
          base_url: "http://localhost:9999/webhook",
          auth: %{type: "none"},
          timeout_ms: 5000
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription!(conn) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        connection_id: conn.id,
        event_type: "widget.updated",
        version: 1,
        transform_script: "-- noop"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
