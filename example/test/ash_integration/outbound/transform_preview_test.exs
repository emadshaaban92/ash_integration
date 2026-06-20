defmodule Example.Outbound.TransformPreviewTest do
  @moduledoc """
  Tests the operator **transform preview** (`AshIntegration.Outbound.Delivery.Transform.Preview`):
  it builds a sample event from the producer's `example/1` and runs the transform,
  returning input + output. It must NOT deliver anything, persist an Event, or
  touch suspension counters. (The legacy real-record preview was removed: `produce/3`
  consumes `{changeset, record}` pairs, which a read-only preview can't synthesize.)
  """
  use Example.DataCase, async: false

  require Ash.Query

  alias AshIntegration.Outbound.Delivery.Transform
  alias Example.Outbound.{Connection, Subscription}

  setup do
    owner = create_user!()
    %{owner: owner, connection: create_connection!(owner)}
  end

  test "runs the transform against the producer's example sample — without delivering", %{
    owner: owner,
    connection: dest
  } do
    sub = create_subscription!(dest, transform_source: "-- noop")

    assert {:ok, result} = Transform.Preview.run(sub.id, owner)
    assert result.outcome == :ok
    # The sample is the producer's example/1 (not a real record — preview is read-only).
    refute result.source.real?
    assert result.input.data.name == "Sample Widget"
    # The event key is derived by the producer's event_key/2 from the example.
    assert result.input.event_key == "widget-id"
    # The output is the fully-resolved transport-shaped descriptor: routing (URL),
    # the pre-seeded wire headers, and the body — exactly what dispatch would send.
    assert result.output["url"] == "http://localhost:9999/webhook"
    assert result.output["method"] == "post"
    assert result.output["headers"]["x-event-type"] == "widget.updated"
    assert result.output["body"]["name"] == "Sample Widget"
  end

  test "the descriptor excludes the signature (a live carve-out, added at delivery)", %{
    owner: owner
  } do
    create_widget!(owner)
    dest = signing_connection!(owner)
    sub = create_subscription!(dest, transform_source: "-- noop")

    assert {:ok, %{outcome: :ok, output: output}} = Transform.Preview.run(sub.id, owner)
    assert output["url"]
    # Even with a signing secret configured, the design-time descriptor carries no
    # signature — it (like auth) is computed live at delivery, not snapshotted.
    refute Map.has_key?(output["headers"], "x-signature")
  end

  test "no delivery, no Event row, no health side effects", %{owner: owner, connection: dest} do
    create_widget!(owner)
    sub = create_subscription!(dest, transform_source: "-- noop")

    assert {:ok, %{outcome: :ok}} = Transform.Preview.run(sub.id, owner)

    assert Ash.count!(Example.Outbound.Event, authorize?: false) == 0
    assert Ash.count!(Example.Outbound.Log, authorize?: false) == 0
    refute reload(dest).suspended
    refute reload(sub).suspended
  end

  test "a transform that skips reports :skipped with no output", %{owner: owner, connection: dest} do
    create_widget!(owner)

    sub =
      create_subscription!(dest,
        transform_source: "function transform(event, defaults) return nil end"
      )

    assert {:ok, result} = Transform.Preview.run(sub.id, owner)
    assert result.outcome == :skipped
    assert result.output == nil
  end

  test "a transform error is reported with the message", %{owner: owner, connection: dest} do
    create_widget!(owner)

    # The save-time smoke gate runs the script against the producer's example/1 —
    # the same sample this preview uses — so a normally-created subscription can't
    # reach the :error branch. Seed one past the gate to prove the preview still
    # surfaces a transform error (legacy rows, or a producer example that drifted
    # after save, can still land here).
    sub =
      Ash.Seed.seed!(Subscription, %{
        connection_id: dest.id,
        event_type: "widget.updated",
        version: 1,
        transform_source: "error('boom')"
      })

    assert {:ok, result} = Transform.Preview.run(sub.id, owner)
    assert result.outcome == :error
    assert result.error
    assert result.output == nil
  end

  test "returns {:error, :not_found} for an unreadable subscription", %{owner: owner} do
    assert Transform.Preview.run(Ash.UUIDv7.generate(), owner) == {:error, :not_found}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

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

  defp create_widget!(owner, attrs \\ []) do
    defaults = %{name: "w-#{System.unique_integer([:positive])}", stock: 1}

    Example.Catalog.Widget
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)), actor: owner)
    |> Ash.create!(actor: owner)
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

  defp signing_connection!(owner) do
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
          timeout_ms: 5000,
          signing: %{type: "stripe", secret: "shh", header_name: "x-signature"}
        }
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_subscription!(dest, overrides) do
    attrs =
      Map.merge(
        %{
          connection_id: dest.id,
          event_type: "widget.updated",
          version: 1,
          transform_source: "-- noop"
        },
        Map.new(overrides)
      )

    Subscription
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp reload(%resource{id: id}), do: Ash.get!(resource, id, authorize?: false)
end
