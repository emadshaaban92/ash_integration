defmodule AshIntegration.Outbound.Delivery.Transform.Limits do
  @moduledoc """
  Runtime-neutral resource limits for a single transform execution.

  Every transform runtime is bounded on the same three axes; each
  `AshIntegration.Outbound.Delivery.Transform.Runtime` implementation maps these
  onto its native primitives:

  | Field               | Meaning                       | Lua (luerl)      | WASM (Wasmtime)     |
  | ------------------- | ----------------------------- | ---------------- | ------------------- |
  | `:timeout_ms`       | wall-clock ceiling            | `max_time`       | epoch interruption  |
  | `:max_steps`        | CPU / work budget             | `max_reductions` | fuel                |
  | `:max_memory_words` | memory ceiling (8-byte words) | `:max_heap_size` | linear-memory pages |

  Keeping the vocabulary uniform means an operator sees the same failure
  modes ("timed out", "exceeded its step budget", "exceeded its memory
  budget") regardless of which language a subscription's transform happens to
  be written in. A runtime whose native unit differs (WASM counts memory in
  64KiB pages, not BEAM words) converts at its own edge rather than leaking
  that unit up to the caller.
  """

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_steps: pos_integer(),
          max_memory_words: pos_integer()
        }

  @enforce_keys [:timeout_ms, :max_steps, :max_memory_words]
  defstruct [:timeout_ms, :max_steps, :max_memory_words]
end
