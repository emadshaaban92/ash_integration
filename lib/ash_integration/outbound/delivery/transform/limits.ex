defmodule AshIntegration.Outbound.Delivery.Transform.Limits do
  @moduledoc """
  Runtime-neutral resource limits for a single transform execution.

  Every transform runtime is bounded on the same three axes; each
  `AshIntegration.Outbound.Delivery.Transform.Runtime` implementation maps these
  onto its native primitives:

  | Field               | Meaning                       | Lua `0.4` (luerl)      | Lua `1.0` (own VM)   | WASM (Wasmtime)     |
  | ------------------- | ----------------------------- | ---------------------- | -------------------- | ------------------- |
  | `:timeout_ms`       | wall-clock ceiling            | outer Task             | outer Task           | epoch interruption  |
  | `:max_steps`        | CPU / work budget             | `max_reductions`       | `max_instructions`   | fuel                |
  | `:max_memory_words` | memory ceiling (8-byte words) | runner `:max_heap_size` | Task `:max_heap_size` | linear-memory pages |

  Keeping the vocabulary uniform means an operator sees the same failure
  modes ("timed out", "exceeded its step budget", "exceeded its memory
  budget") regardless of which language a subscription's transform happens to
  be written in. A runtime whose native unit differs (WASM counts memory in
  64KiB pages, not BEAM words) converts at its own edge rather than leaking
  that unit up to the caller.

  Uniform *vocabulary* is not uniform *enforcement*, and this struct deliberately
  does not pretend otherwise. `:max_steps` names a work budget; what happens when
  a script exhausts it is the backend's business, and the two Lua backends differ
  in a way a script can observe — `lua 0.4` kills the process running the Lua code
  (uncatchable), `lua 1.0` raises a `pcall`-catchable Lua error. Wall-clock, by
  contrast, is the caller's `Task` on both: `lua 0.4`'s `max_time` looks like an
  inner ceiling but is never consulted while a script is still running once a
  step budget is set. See
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.Compat`.
  """

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_steps: pos_integer(),
          max_memory_words: pos_integer()
        }

  @enforce_keys [:timeout_ms, :max_steps, :max_memory_words]
  defstruct [:timeout_ms, :max_steps, :max_memory_words]
end
