defmodule AshIntegration.Outbound.Delivery.Transform.Limits do
  @moduledoc """
  Runtime-neutral resource limits for a single transform execution.

  Every transform runtime is bounded on the same three axes; each
  `AshIntegration.Outbound.Delivery.Transform.Runtime` implementation maps these
  onto its native primitives:

  | Field               | Meaning                       | Lua (`lua 1.0`'s VM)  | WASM (Wasmtime)     |
  | ------------------- | ----------------------------- | --------------------- | ------------------- |
  | `:timeout_ms`       | wall-clock ceiling            | outer Task            | epoch interruption  |
  | `:max_steps`        | CPU / work budget             | `max_instructions`    | fuel                |
  | `:max_memory_words` | memory ceiling (8-byte words) | Task `:max_heap_size` | linear-memory pages |

  Keeping the vocabulary uniform means an operator sees the same failure
  modes ("timed out", "exceeded its step budget", "exceeded its memory
  budget") regardless of which language a subscription's transform happens to
  be written in. A runtime whose native unit differs (WASM counts memory in
  64KiB pages, not BEAM words) converts at its own edge rather than leaking
  that unit up to the caller.

  Uniform *vocabulary* is not uniform *enforcement*, and this struct deliberately
  does not pretend otherwise. `:max_steps` names a work budget; how a runtime
  stops a script that exhausts one is its own business. What every runtime owes
  the caller is the *outcome*: exhausting the budget must end the run in an
  error, never in a result. The Lua runtime raises its breach as an ordinary,
  `pcall`-catchable Lua error, so it enforces that outcome explicitly — see
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Budget`.
  """

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_steps: pos_integer(),
          max_memory_words: pos_integer()
        }

  @enforce_keys [:timeout_ms, :max_steps, :max_memory_words]
  defstruct [:timeout_ms, :max_steps, :max_memory_words]
end
