defmodule AshIntegration.Inbound.Declare.Handler do
  @moduledoc """
  Behaviour for a command type's **handler** — one host module per command type
  that maps a validated wire payload to the declared action's input.

  The thinness is a design constraint, not a trust boundary (the handler is host
  code, trusted). Three callbacks is the whole surface; deliberately absent are a
  `produce`-style capture (commands arrive, they aren't observed), a `project`
  fan-out (a command has exactly one executor), success/failure hooks (side
  effects belong in the Ash action's own changes, transactional with the apply),
  and `classify_error/1` (terminal-vs-transient is core policy — a per-handler
  override would let one handler quietly turn a deterministic failure into an
  infinite retry).

  Reference it from a `command` declaration in the `inbound_commands` DSL:

      inbound_commands do
        command "record_partner_ref" do
          action :record_partner_ref
          handler MyApp.Inbound.RecordPartnerRef
        end
      end

      defmodule MyApp.Inbound.RecordPartnerRef do
        use AshIntegration.Inbound.Declare.Handler

        @impl true
        def build_input(payload, ctx) do
          {:ok,
           MyApp.Catalog.Product
           |> Ash.Changeset.for_update(:record_partner_ref, %{ref: payload["ref"]},
                actor: ctx.actor)}
        end

        @impl true
        def example, do: %{"product_id" => "…", "ref" => "PARTNER-123"}
      end
  """

  @typedoc """
  The execution context handed to `build_input/2`: the resolved actor, plus the
  command row's identifying facts (and, for response commands, the source
  delivery's identifiers).
  """
  @type ctx :: %{
          required(:actor) => term(),
          required(:command_id) => String.t(),
          required(:command_source) => String.t(),
          required(:command_type) => String.t(),
          required(:occurrence_id) => term(),
          optional(:source_delivery_id) => term()
        }

  @doc """
  Map the decoded `payload` + `ctx` to a prepared changeset (or action input) for
  the **declared** `(resource, action)`. Returning a changeset rather than a bare
  map is the honest scope: payload → record resolution ("find the order by the
  partner's reference") is irreducibly host logic.

  Returns `{:ok, changeset}` or `{:error, reason}`. A raising/erroring
  `build_input` is **terminal** (deterministic on the same payload).
  """
  @callback build_input(payload :: map(), ctx :: ctx()) ::
              {:ok, Ash.Changeset.t()} | {:error, term()}

  @doc """
  Optional: derive the ordering `partition_key` stored on the row (reserved for a
  future per-key ordering gate). Absent = `nil` key = never gated.
  """
  @callback partition_key(payload :: map()) :: String.t() | nil

  @doc """
  A sample wire payload. Powers the dashboard preview and the golden-payload
  contract test (`build_input(example(), ctx)` must succeed for every registered
  handler) — the mirror of the outbound Producer's `example/1`.
  """
  @callback example() :: map()

  @optional_callbacks partition_key: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour AshIntegration.Inbound.Declare.Handler
    end
  end
end
