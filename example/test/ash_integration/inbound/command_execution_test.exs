defmodule Example.Inbound.CommandExecutionTest do
  @moduledoc """
  Phase 0 of the inbound-commands design: the transport-agnostic command core
  (`AshIntegration.Inbound.Execute`), the host-owned `CommandExecution` resource,
  the claim/lease/fence machinery, and the `inbound_commands` DSL + registry —
  driven from a routing map, with no real transport.
  """
  use Example.DataCase, async: false

  import Example.IntegrationHelpers, only: [create_user!: 0]

  require Ash.Query

  alias AshIntegration.Inbound.Declare.Registration
  alias AshIntegration.Inbound.Declare.Registry
  alias AshIntegration.Inbound.Execute
  alias AshIntegration.Inbound.Execute.Claimer
  alias AshIntegration.Outbound.Retention
  alias Example.Catalog.Product
  alias Example.Inbound.CommandExecution

  setup do
    user = create_user!()
    product = create_product!()
    %{user: user, product: product, routing: Registry.build()}
  end

  # ── Registry / DSL ────────────────────────────────────────────────────────

  test "the registry routes the declared command type to its resource/action/handler" do
    routing = Registry.build()

    assert %Registration{
             command_type: "record_partner_ref",
             resource: Example.Catalog.Product,
             action: :record_partner_ref,
             handler: Example.Inbound.RecordPartnerRef
           } = routing["record_partner_ref"]
  end

  test "verify! passes for the example catalog (unique types, callbacks present)" do
    assert :ok = Registry.verify!()
  end

  test "golden payload: build_input(example(), ctx) succeeds and targets the declared action",
       %{user: user} do
    for {type, %Registration{} = reg} <- Registry.build() do
      # Seed a record at the example's id so the handler's lookup resolves.
      seed_product_with_example_id(reg)
      ctx = ctx_for(type, user)

      assert {:ok, %Ash.Changeset{} = changeset} =
               reg.handler.build_input(reg.handler.example(), ctx)

      assert changeset.resource == reg.resource
      assert changeset.action.name == reg.action
    end
  end

  # ── Happy path ────────────────────────────────────────────────────────────

  test "applies an inbound command exactly once under the actor", ctx do
    outcome =
      handle(
        command("record_partner_ref", %{"product_id" => ctx.product.id, "ref" => "PARTNER-1"}),
        ctx
      )

    assert {:applied, %{"id" => _}} = outcome
    assert reload(ctx.product).partner_ref == "PARTNER-1"

    [row] = all_rows()
    assert row.state == :applied
    assert row.result == %{"id" => to_string(ctx.product.id)}
    assert row.applied_at
    assert row.attempts == 1
    # The lease is released on a terminal transition.
    refute row.claimed_at
  end

  # ── Admission failures ────────────────────────────────────────────────────

  test "an unknown command type records a terminal :failed row", ctx do
    assert {:failed, _} =
             Execute.handle(
               %{"command" => "no_such_command", "command_id" => "u1", "payload" => %{}},
               meta(ctx)
             )

    [row] = all_rows()
    assert row.state == :failed
    assert row.command_type == "no_such_command"
    assert row.raw_command_type == "no_such_command"
    assert row.error =~ "unknown command type"
  end

  test "a payload with no command_id yields no row (identity unrecoverable)", ctx do
    assert {:failed, :missing_command_id} =
             Execute.handle(%{"command" => "record_partner_ref", "payload" => %{}}, meta(ctx))

    assert all_rows() == []
  end

  test "case-insensitive command type: normalized at the choke point", ctx do
    assert {:applied, _} =
             handle(
               command("RECORD_PARTNER_REF", %{"product_id" => ctx.product.id, "ref" => "X"}),
               ctx
             )

    [row] = all_rows()
    assert row.command_type == "record_partner_ref"
    assert row.raw_command_type == "RECORD_PARTNER_REF"
  end

  # ── Idempotency ───────────────────────────────────────────────────────────

  test "a duplicate of an applied command replays the cached result without re-executing", ctx do
    cmd = command("record_partner_ref", %{"product_id" => ctx.product.id, "ref" => "FIRST"})

    assert {:applied, result} = handle(cmd, ctx)

    # Tamper with the product so a re-execution would be observable.
    ctx.product
    |> Ash.Changeset.for_update(:record_partner_ref, %{partner_ref: "MANUAL"}, authorize?: false)
    |> Ash.update!()

    assert {:duplicate, :applied, ^result} = handle(cmd, ctx)

    # The handler did NOT run again — our manual value survives.
    assert reload(ctx.product).partner_ref == "MANUAL"
    assert length(all_rows()) == 1
  end

  test "a duplicate of a failed command replays the cached error", ctx do
    envelope = %{"command" => "no_such_command", "command_id" => "dup-fail", "payload" => %{}}

    assert {:failed, _} = Execute.handle(envelope, meta(ctx))
    assert {:duplicate, :failed, error} = Execute.handle(envelope, meta(ctx))
    assert error =~ "unknown command type"
    assert length(all_rows()) == 1
  end

  # ── Terminal vs transient ─────────────────────────────────────────────────

  test "a terminal business rejection (missing target record) fails terminally and is not retried",
       ctx do
    cmd = command("record_partner_ref", %{"product_id" => Ash.UUID.generate(), "ref" => "X"})

    assert {:failed, _} = handle(cmd, ctx)

    [row] = all_rows()
    assert row.state == :failed
    assert row.attempts == 1
  end

  test "a transient infra failure backs off and leaves the row :pending (relay retries)", ctx do
    {:ok, row} = Execute.admit(explode_command(ctx.product.id), meta(ctx), explode_routing())

    assert {:transient, _} = Execute.execute(row, explode_routing())

    reloaded = reload_row(row.id)
    assert reloaded.state == :pending
    assert reloaded.next_attempt_at
    refute reloaded.claimed_at
  end

  test "a transient failure at the attempt ceiling dead-letters", ctx do
    {:ok, row} = Execute.admit(explode_command(ctx.product.id), meta(ctx), explode_routing())

    # Jump to the ceiling without disturbing the claim token (the fence must match).
    bump_attempts_to_ceiling(row.id)
    at_ceiling = reload_row(row.id)

    assert {:dead_lettered, _} = Execute.execute(at_ceiling, explode_routing())

    reloaded = reload_row(row.id)
    assert reloaded.state == :dead_lettered
    assert reloaded.error
  end

  # ── The fence ─────────────────────────────────────────────────────────────

  test "a superseded claimer's apply rolls back, leaving no trace", ctx do
    {:ok, row} =
      Execute.admit(
        command("record_partner_ref", %{"product_id" => ctx.product.id, "ref" => "GHOST"}),
        meta(ctx),
        ctx.routing
      )

    # Simulate another pass having re-claimed the row: the in-hand struct now holds
    # a stale claim token that no longer matches the committed `claimed_at`.
    stale = %{row | claimed_at: DateTime.add(row.claimed_at, -30, :second)}

    assert {:transient, :superseded} = Execute.execute(stale, ctx.routing)

    # The handler's product update was rolled back with the failed fence.
    assert reload(ctx.product).partner_ref == nil
    assert reload_row(row.id).state == :pending
  end

  # ── Claim gating ──────────────────────────────────────────────────────────

  test "the claimer skips rows over the attempt ceiling and inside their backoff", ctx do
    claimable = seed_row(ctx, command_id: "claimable", state: :pending)
    over_ceiling = seed_row(ctx, command_id: "over", state: :pending, attempts: 99)

    backed_off =
      seed_row(ctx,
        command_id: "backoff",
        state: :pending,
        next_attempt_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    claimed_ids = Claimer.claim(50) |> Enum.map(& &1.id)

    assert claimable.id in claimed_ids
    refute over_ceiling.id in claimed_ids
    refute backed_off.id in claimed_ids

    # The claim bumped attempts and stamped the lease on the one it took.
    assert reload_row(claimable.id).attempts == 1
    assert reload_row(claimable.id).claimed_at
  end

  # ── Retention ─────────────────────────────────────────────────────────────

  test "retention reaps terminal command rows but keeps dead-lettered and pending", ctx do
    old = DateTime.add(DateTime.utc_now(), -100, :day)

    applied = seed_row(ctx, command_id: "r-applied", state: :applied, updated_at: old)
    failed = seed_row(ctx, command_id: "r-failed", state: :failed, updated_at: old)
    dead = seed_row(ctx, command_id: "r-dead", state: :dead_lettered, updated_at: old)
    pending = seed_row(ctx, command_id: "r-pending", state: :pending, updated_at: old)

    assert %{command_execution: _} = Retention.sweep()

    ids = all_rows() |> MapSet.new(& &1.id)

    refute MapSet.member?(ids, applied.id), "old :applied should be reaped"
    refute MapSet.member?(ids, failed.id), "old :failed should be reaped"
    assert MapSet.member?(ids, dead.id), ":dead_lettered is never reaped"
    assert MapSet.member?(ids, pending.id), ":pending is never reaped"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp handle(envelope, ctx), do: Execute.handle(envelope, meta(ctx), ctx.routing)

  defp command(type, payload),
    do: %{
      "command" => type,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "payload" => payload
    }

  defp explode_command(id),
    do: %{
      "command" => "explode",
      "command_id" => "ex-#{System.unique_integer([:positive])}",
      "payload" => %{"id" => id}
    }

  defp explode_routing do
    %{
      "explode" => %Registration{
        command_type: "explode",
        resource: Example.InboundTestSupport.Exploder,
        action: :explode,
        handler: Example.InboundTestSupport.ExplodeHandler
      }
    }
  end

  defp meta(ctx), do: %{transport: :http, command_source: "test-source", actor_id: ctx.user.id}

  defp ctx_for(type, user) do
    %{
      actor: user,
      command_id: "golden",
      command_source: "test",
      command_type: type,
      occurrence_id: Ash.UUID.generate(),
      source_delivery_id: nil
    }
  end

  defp create_product! do
    Product
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Widget", sku: "SKU-#{System.unique_integer([:positive])}"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_product_with_example_id(%Registration{handler: Example.Inbound.RecordPartnerRef}) do
    Ash.Seed.seed!(Product, %{
      id: "00000000-0000-0000-0000-000000000000",
      name: "Golden",
      sku: "GOLDEN-#{System.unique_integer([:positive])}"
    })
  end

  defp seed_product_with_example_id(_), do: :ok

  defp seed_row(ctx, opts) do
    Ash.Seed.seed!(
      CommandExecution,
      Map.merge(
        %{
          command_source: "test-source",
          command_id: opts[:command_id],
          command_type: "record_partner_ref",
          raw_command_type: "record_partner_ref",
          transport: :http,
          state: opts[:state],
          attempts: Keyword.get(opts, :attempts, 0),
          actor_id: ctx.user.id
        },
        seed_optionals(opts)
      )
    )
  end

  defp seed_optionals(opts) do
    [:updated_at, :next_attempt_at, :claimed_at]
    |> Enum.reduce(%{}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp bump_attempts_to_ceiling(id) do
    Example.Repo.query!(
      "UPDATE inbound_command_executions SET attempts = $1 WHERE id = $2",
      [AshIntegration.Inbound.Execute.Supervisor.max_attempts(), Ecto.UUID.dump!(id)]
    )
  end

  defp reload(product), do: Ash.get!(Product, product.id, authorize?: false)

  defp reload_row(id), do: Ash.get!(CommandExecution, id, authorize?: false)

  defp all_rows, do: Ash.read!(CommandExecution, authorize?: false)
end
