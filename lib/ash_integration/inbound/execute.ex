defmodule AshIntegration.Inbound.Execute do
  @moduledoc """
  The transport-agnostic, DSL-independent **command-execution core**: two
  composable halves driven from a plain `%{canonical_command_type =>
  %Registration{}}` routing map. Nothing here names a transport, a resource, or an
  action — those live in the routing data and the `CommandExecution` resource.

      handle(raw, meta, routing) →
          {:applied, result}
        | {:failed, reason}
        | {:dead_lettered, reason}
        | {:transient, reason}        # row left :pending; a relay/redelivery retries
        | {:duplicate, state, cached} # cached = result on :applied, error on :failed

  ## Admission (decode → normalize → route → record)

  Produces a committed `:pending` row (its own transaction — never inside the
  apply) or a fast duplicate conflict. A malformed payload whose identity is
  recoverable records a terminal `:failed` row; one with no readable `command_id`
  cannot be an idempotency record and returns `{:failed, …}` with no row.

  Admission classifies its *own* failures with the same terminal/transient split
  as execution: when the record insert fails for an infrastructure reason (a DB
  blip) and there is no existing row to dedup against, admission returns
  `{:transient, …}` — **not** `{:failed, …}` — so an at-least-once transport
  re-presents the command rather than dropping it. `{:failed, …}` always means
  terminal (deterministic; re-presenting won't help).

  ## Execution (claim → build → apply → classify → finalize)

  `apply` (the host's declared Ash action under the snapshotted actor) and the
  finalizing transition commit in **one transaction fenced on the claim token**
  (`claimed_at`). A superseded claimer's finalize matches zero rows, raises inside
  the transaction, and rolls the handler's whole effect back — exactly one
  claimer's apply-plus-finalize ever commits.

  `handle/3` is the inline (push-transport) entrypoint: admit, then — for a fresh
  `:pending` row — execute immediately in the caller's process. The command relay
  drives `execute/2` for response rows and for crash-recovery of any stale
  `:pending` row regardless of transport.
  """

  require Ash.Query
  require Logger

  import Ash.Expr

  alias AshIntegration.Inbound.Declare.Registry
  alias AshIntegration.Inbound.Execute.Supervisor, as: Stage

  @type meta :: %{
          required(:transport) => atom(),
          required(:command_source) => String.t(),
          optional(:actor_id) => term() | nil,
          optional(:partition_key) => String.t() | nil
        }

  @type outcome ::
          {:applied, map()}
          | {:failed, term()}
          | {:dead_lettered, term()}
          | {:transient, term()}
          | {:duplicate, atom(), term()}

  # ── Inline (push-transport) entrypoint ──────────────────────────────────

  @doc """
  Admit `raw` under `meta`, then — for a fresh `:pending` row — execute it inline.
  A duplicate or terminal admission failure short-circuits without execution.
  """
  @spec handle(term(), meta(), map()) :: outcome()
  def handle(raw, meta, routing \\ Registry.routing()) do
    case admit(raw, meta, routing) do
      {:ok, row} -> execute(row, routing)
      other -> other
    end
  end

  # ── Admission ────────────────────────────────────────────────────────────

  @doc """
  Decode → normalize → route-check → record. Returns `{:ok, pending_row}`,
  `{:duplicate, state, cached}`, `{:failed, reason}` (terminal — a recorded
  `:failed` row when identity was recoverable, no row otherwise), or
  `{:transient, reason}` (the record insert failed for an infrastructure reason
  with no existing row — re-present the command).
  """
  @spec admit(term(), meta(), map()) ::
          {:ok, Ash.Resource.record()}
          | {:duplicate, atom(), term()}
          | {:failed, term()}
          | {:transient, term()}
  def admit(raw, meta, routing \\ Registry.routing()) do
    with {:ok, decoded} <- decode(raw),
         {:ok, fields} <- extract(decoded) do
      route(fields, meta, routing)
    end
  end

  # A malformed-but-identifiable command: record a terminal `:failed` row (the
  # operator's evidence), since redelivery can't fix a deterministic decode error.
  defp route(%{malformed: reason} = fields, meta, _routing) when is_binary(reason) do
    insert_failed(meta, fields, "", "malformed command: #{reason}")
  end

  defp route(fields, meta, routing) do
    canonical = normalize(fields.command_type)

    case Map.fetch(routing, canonical) do
      {:ok, registration} ->
        insert_pending(meta, fields, canonical, registration)

      :error ->
        insert_failed(meta, fields, canonical, "unknown command type #{inspect(canonical)}")
    end
  end

  # ── Execution ──────────────────────────────────────────────────────────

  @doc """
  Execute an already-claimed `:pending` row (its `claimed_at` is the fence token):
  build the input, apply the declared action and finalize in one fenced
  transaction, and classify any failure. Used by both the inline entrypoint and
  the command relay.
  """
  @spec execute(Ash.Resource.record(), map()) :: outcome()
  def execute(row, routing \\ Registry.routing()) do
    case Map.fetch(routing, row.command_type) do
      {:ok, registration} ->
        apply_and_finalize(row, registration)

      :error ->
        # The catalog changed since admission. Terminal — redelivery won't teach
        # the host a command type it no longer declares.
        finalize_failure(row, "unknown command type #{inspect(row.command_type)} at execution")
        {:failed, :unknown_command}
    end
  end

  defp apply_and_finalize(row, registration) do
    ctx = build_ctx(row, registration)

    case safe_build_input(registration, row, ctx) do
      {:ok, changeset} ->
        run_fenced(row, registration, changeset)

      {:error, reason} ->
        # A deterministic build failure (returned or raised) is terminal — the same
        # payload yields the same outcome, so retrying is wasted work.
        finalize_failure(row, "build_input failed: #{format_error(reason)}")
        {:failed, reason}
    end
  end

  defp safe_build_input(registration, row, ctx) do
    case build_input(registration.handler, row.payload || %{}, ctx) do
      {:ok, %Ash.Changeset{} = changeset} -> {:ok, changeset}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_build_input_return, other}}
    end
  rescue
    e -> {:error, e}
  end

  # Apply + finalize in ONE transaction, fenced on the claim token. A stale
  # claimer's `:apply_success` matches zero rows → rollback the whole effect.
  # Host-action failures — whether the action *returns* `{:error, …}` or *raises*
  # (an infra fault aborts and re-raises out of the transaction) — roll the action
  # back, then the outcome is recorded on the row in a separate committed write,
  # classified terminal vs. transient.
  defp run_fenced(row, registration, changeset) do
    assert_target!(changeset, registration)

    row
    |> apply_in_transaction(changeset)
    |> resolve_outcome(row)
  rescue
    e ->
      # The action raised and aborted the transaction (its effect rolled back).
      # Classify the raised fault the same way as a returned error.
      classify_and_record(row, e)
  end

  defp apply_in_transaction(row, changeset) do
    transaction(fn ->
      case run_changeset(changeset) do
        {:ok, record, notifications} -> commit_apply_success(row, record, notifications)
        {:error, error} -> rollback({classify(error), error})
      end
    end)
  end

  defp commit_apply_success(row, record, host_notifications) do
    # `:apply_success` commits inside this same transaction, so its notifications —
    # like the host action's — must be collected and emitted *after* the commit
    # (Ash can't flush from a manually-managed transaction). Carry both sets out.
    row
    |> Ash.Changeset.for_update(:apply_success, %{result: result_of(record)}, authorize?: false)
    |> Ash.Changeset.filter(expr(claimed_at == ^row.claimed_at))
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> case do
      {:ok, _record, finalize_notifications} ->
        {:applied, result_of(record), host_notifications ++ finalize_notifications}

      {:error, _stale} ->
        rollback(:superseded)
    end
  end

  defp resolve_outcome({:ok, {:applied, res, notifications}}, row),
    do: applied(row, res, notifications)

  defp resolve_outcome({:error, :superseded}, _row), do: {:transient, :superseded}
  defp resolve_outcome({:error, {:terminal, error}}, row), do: terminal(row, error)
  defp resolve_outcome({:error, {:transient, error}}, row), do: transient(row, error)

  defp classify_and_record(row, error) do
    case classify(error) do
      :transient -> transient(row, error)
      :terminal -> terminal(row, error)
    end
  end

  defp applied(row, res, notifications) do
    # Emit the host action's (and the finalize's) notifications now that the fenced
    # transaction has committed — so an action applied via a command fans out to
    # PubSub / ash_events / LiveView subscribers exactly as the same action does
    # when run normally.
    Ash.Notifier.notify(notifications)

    :telemetry.execute(
      [:ash_integration, :command, :applied],
      %{count: 1, attempts: row.attempts},
      telemetry_meta(row)
    )

    {:applied, res}
  end

  defp terminal(row, error) do
    finalize_failure(row, format_error(error))
    {:failed, error}
  end

  defp transient(row, error) do
    if row.attempts >= Stage.max_attempts() do
      # Only report the dead-letter once it actually applied; a stale no-op means
      # another pass already owns the row's outcome.
      case fenced_update(row, :dead_letter, %{error: scrub(format_error(error))}) do
        {:ok, _} -> emit_command_event(:dead_lettered, row)
        {:error, _stale} -> :ok
      end

      {:dead_lettered, error}
    else
      fenced_update(row, :record_attempt_error, %{
        error: scrub(format_error(error)),
        next_attempt_at: backoff_until(row.attempts)
      })

      {:transient, error}
    end
  end

  defp finalize_failure(row, error) do
    case fenced_update(row, :apply_failure, %{error: scrub(error)}) do
      {:ok, _} -> emit_command_event(:failed, row)
      {:error, _stale} -> :ok
    end
  end

  defp emit_command_event(event, row) do
    :telemetry.execute(
      [:ash_integration, :command, event],
      %{count: 1, attempts: row.attempts},
      telemetry_meta(row)
    )
  end

  # ── Decode / extract / normalize ──────────────────────────────────────────

  defp decode(raw) when is_map(raw), do: {:ok, raw}

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:failed, {:decode, "payload is not a JSON object"}}
      {:error, e} -> {:failed, {:decode, Exception.message(e)}}
    end
  end

  defp decode(_), do: {:failed, {:decode, "unsupported payload type"}}

  # Pull the envelope fields. `command_id` is the idempotency half that cannot be
  # synthesized: without it there is nothing to dedup against, so admission has no
  # row to record (`{:failed, …}` carries the signal via the transport).
  defp extract(decoded) do
    command_id = decoded["command_id"] || decoded["commandId"]
    command = decoded["command"] || decoded["command_type"]
    payload = decoded["payload"]

    cond do
      blank?(command_id) ->
        {:failed, :missing_command_id}

      blank?(command) ->
        {:ok,
         %{
           command_id: to_string(command_id),
           command_type: nil,
           payload: payload,
           malformed: "missing command"
         }}

      true ->
        {:ok,
         %{
           command_id: to_string(command_id),
           command_type: to_string(command),
           payload: payload,
           malformed: nil
         }}
    end
  end

  defp normalize(type) when is_binary(type), do: String.downcase(type)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  # ── Row insertion ──────────────────────────────────────────────────────

  # Insert the `:pending` row, insert-as-claim (push transports execute inline, so
  # the row is born claimed with `attempts: 1`). A unique conflict on the identity
  # is the dedup signal: read the existing row and answer `{:duplicate, …}`.
  defp insert_pending(meta, fields, canonical, registration) do
    now = DateTime.utc_now()

    params = %{
      command_source: meta.command_source,
      command_id: fields.command_id,
      command_type: canonical,
      raw_command_type: fields.command_type,
      transport: Map.fetch!(meta, :transport),
      partition_key: partition_key(meta, registration, fields.payload),
      payload: fields.payload,
      state: :pending,
      attempts: 1,
      claimed_at: now,
      actor_id: Map.get(meta, :actor_id)
    }

    create_or_duplicate(meta, fields, params)
  end

  defp insert_failed(meta, fields, canonical, error) do
    params = %{
      command_source: meta.command_source,
      command_id: fields.command_id,
      command_type: canonical,
      raw_command_type: fields.command_type || "",
      transport: Map.fetch!(meta, :transport),
      payload: fields.payload,
      state: :failed,
      error: scrub(error),
      actor_id: Map.get(meta, :actor_id)
    }

    case create_or_duplicate(meta, fields, params) do
      {:ok, _row} ->
        :telemetry.execute(
          [:ash_integration, :command, :failed],
          %{count: 1, attempts: 0},
          %{command_type: canonical, command_source: meta.command_source}
        )

        {:failed, error}

      other ->
        other
    end
  end

  defp create_or_duplicate(meta, fields, params) do
    resource = AshIntegration.command_execution_resource()

    resource
    |> Ash.Changeset.for_create(:admit, params, authorize?: false)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, row} ->
        {:ok, row}

      {:error, error} ->
        # The expected `:error` here is the identity unique-violation — read the
        # existing row and answer `{:duplicate, …}`. With no existing row the insert
        # genuinely failed: classify it so a transient DB blip is reported
        # `{:transient, …}` (re-present) rather than terminal `{:failed, …}` (drop) —
        # this admission path is the seam every at-least-once transport sits on.
        case get_by_identity(meta.command_source, fields.command_id) do
          {:ok, %{} = existing} -> duplicate(existing)
          _ -> admission_failure(error)
        end
    end
  end

  defp admission_failure(error) do
    case classify(error) do
      :transient -> {:transient, {:admission, format_error(error)}}
      :terminal -> {:failed, {:admission, format_error(error)}}
    end
  end

  defp duplicate(%{state: :applied} = row) do
    :telemetry.execute([:ash_integration, :command, :duplicate], %{count: 1}, %{
      command_type: row.command_type,
      command_source: row.command_source,
      original_state: :applied
    })

    {:duplicate, :applied, row.result}
  end

  defp duplicate(%{state: :failed} = row) do
    :telemetry.execute([:ash_integration, :command, :duplicate], %{count: 1}, %{
      command_type: row.command_type,
      command_source: row.command_source,
      original_state: :failed
    })

    {:duplicate, :failed, row.error}
  end

  defp duplicate(row) do
    :telemetry.execute([:ash_integration, :command, :duplicate], %{count: 1}, %{
      command_type: row.command_type,
      command_source: row.command_source,
      original_state: row.state
    })

    {:duplicate, row.state, nil}
  end

  defp get_by_identity(command_source, command_id) do
    AshIntegration.command_execution_resource()
    |> Ash.Query.filter(command_source == ^command_source and command_id == ^command_id)
    |> Ash.read_one(authorize?: false)
  end

  defp partition_key(meta, registration, payload) do
    cond do
      is_binary(meta[:partition_key]) ->
        meta[:partition_key]

      registration && function_exported?(registration.handler, :partition_key, 1) ->
        safe_partition_key(registration.handler, payload || %{})

      true ->
        nil
    end
  end

  # The optional `partition_key/1` carries no runtime behavior yet (it feeds the
  # reserved ordering gate), so a raising one must not crash admission and lose the
  # row — fall back to `nil` and log, rather than dropping the command. Mirrors the
  # `safe_build_input/3` posture on the (load-bearing) build path.
  defp safe_partition_key(handler, payload) do
    handler.partition_key(payload)
  rescue
    e ->
      Logger.warning(
        "Inbound command: #{inspect(handler)}.partition_key/1 raised " <>
          "(#{Exception.message(e)}); storing nil partition key."
      )

      nil
  end

  # ── Handler / action plumbing ────────────────────────────────────────────

  defp build_ctx(row, registration) do
    %{
      actor: load_actor(row.actor_id),
      command_id: row.command_id,
      command_source: row.command_source,
      command_type: row.command_type,
      occurrence_id: row.id,
      source_delivery_id: row.source_delivery_id,
      resource: registration.resource,
      action: registration.action
    }
  end

  defp build_input(handler, payload, ctx), do: handler.build_input(payload, ctx)

  defp load_actor(nil), do: nil

  defp load_actor(actor_id) do
    case Ash.get(AshIntegration.actor_resource(), actor_id, authorize?: false) do
      {:ok, actor} -> actor
      _ -> nil
    end
  end

  # Cheap guard against declaration/handler drift: the built changeset must target
  # the declared `(resource, action)`.
  defp assert_target!(%Ash.Changeset{resource: resource, action: action}, registration) do
    action_name = action && action.name

    unless resource == registration.resource and action_name == registration.action do
      raise ArgumentError,
            "handler #{inspect(registration.handler)} built a changeset for " <>
              "#{inspect(resource)}.#{inspect(action_name)}, but command type " <>
              "#{inspect(registration.command_type)} is declared on " <>
              "#{inspect(registration.resource)}.#{inspect(registration.action)}"
    end
  end

  # `return_notifications?: true` so the host action's notifications are collected
  # (not flushed) — it runs inside our manual transaction, where Ash has no commit
  # hook to flush them; `apply_and_finalize` emits them after the commit.
  defp run_changeset(%Ash.Changeset{action_type: :create} = cs),
    do: Ash.create(cs, authorize?: true, return_notifications?: true)

  defp run_changeset(%Ash.Changeset{action_type: :update} = cs),
    do: Ash.update(cs, authorize?: true, return_notifications?: true)

  defp run_changeset(%Ash.Changeset{action_type: :destroy} = cs),
    do: Ash.destroy(cs, return_destroyed?: true, authorize?: true, return_notifications?: true)

  defp result_of(%{id: id}), do: %{"id" => to_string(id)}
  defp result_of(_), do: %{}

  # ── Fenced finalize ──────────────────────────────────────────────────────

  defp fenced_update(row, action, params) do
    row
    |> Ash.Changeset.for_update(action, params, authorize?: false)
    |> Ash.Changeset.filter(expr(claimed_at == ^row.claimed_at))
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, reason} ->
        Logger.debug(
          "Inbound command: #{action} on #{row.id} did not apply " <>
            "(stale claim or transient error): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ── Classification ──────────────────────────────────────────────────────

  # The load-bearing split: terminal = deterministic (will fail identically on
  # retry); transient = infrastructure (retrying is the fix). Business failures
  # (`Invalid`/`Forbidden`) are terminal by construction; everything else is
  # scanned for the signature of an infrastructure fault. Ash captures a raised
  # exception as its `Exception.message/1` string nested in `Ash.Error.Unknown`, so
  # a structural match is brittle — inspecting the whole error and matching the
  # known infra markers is robust to that nesting. A generic bug raise won't match
  # and is correctly treated as terminal (a raising handler is deterministic).
  @infra_markers ["DBConnection", "Postgrex", "ConnectionError", "tcp_closed", ":timeout"]

  defp classify(%Ash.Error.Forbidden{}), do: :terminal
  defp classify(%Ash.Error.Invalid{}), do: :terminal

  defp classify(error) do
    if String.contains?(inspect(error, limit: :infinity), @infra_markers),
      do: :transient,
      else: :terminal
  end

  # ── Backoff ──────────────────────────────────────────────────────────────

  defp backoff_until(attempts) do
    base = Stage.backoff_base_ms()
    max = Stage.backoff_max_ms()
    ms = min(base * Integer.pow(2, max(attempts - 1, 0)), max)
    DateTime.add(DateTime.utc_now(), ms, :millisecond)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp transaction(fun) do
    AshIntegration.repo().transaction(fun)
  end

  defp rollback(reason), do: AshIntegration.repo().rollback(reason)

  defp telemetry_meta(row) do
    %{
      command_type: row.command_type,
      command_source: row.command_source,
      transport: row.transport,
      command_execution_id: row.id
    }
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(%{__struct__: _} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

  # The bounded, scrubbed error column — keep operator messages readable and never
  # let a struct dump or decrypted credential land here.
  defp scrub(nil), do: nil
  defp scrub(error) when is_binary(error), do: String.slice(error, 0, 500)
  defp scrub(error), do: error |> format_error() |> String.slice(0, 500)
end
