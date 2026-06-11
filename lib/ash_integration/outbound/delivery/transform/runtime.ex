defmodule AshIntegration.Outbound.Delivery.Transform.Runtime do
  @moduledoc """
  The runtime-neutral seam between the resolver and a concrete transform
  engine.

  A transform is a **function the author's source exposes**, not an imperative
  chunk that mutates a magic global:

      transform(event, defaults) -> result | nil

  where `event` is the immutable event envelope and `defaults` is the
  transport-shaped delivery descriptor the resolver pre-seeds. The function
  returns the (possibly modified) descriptor to deliver, or `nil`/`:skip` to drop
  the event. A source that exposes no `transform` is a no-op (the pre-seeded
  `defaults` pass through). Defining the contract as *call a function and use its
  return* — rather than *run a script that mutates a global* — is what keeps it
  suitable for functional runtimes and maps 1:1 onto a WASM guest's exported
  `transform`.

  Today the only implementation is `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua`.
  This behaviour exists so that adding a second language — a `.wasm` guest, a
  sandboxed JS/Python engine compiled to WASM, etc. — is an *additive* change
  (a new module behind this behaviour) rather than a rewrite of the resolver.

  ## The boundary is serializable data, not BEAM terms

  `event` and `defaults` are plain maps whose keys and values are
  **JSON-serializable** — the lowest common denominator across every candidate
  runtime. The in-process Lua implementation passes these maps straight
  through (it stringifies atom keys but pays no serialization cost), while a
  future out-of-process or WASM runtime serializes them to JSON/msgpack at its
  own edge. Defining the contract in terms of serializable data — rather than,
  say, luerl tables — is what keeps that future additive.

  ## Resource limits

  Execution is bounded by a runtime-neutral `t:limits/0`
  (`AshIntegration.Outbound.Delivery.Transform.Limits`). Each implementation supplies its own
  config-driven defaults via `c:default_limits/0` and maps the limits onto its
  native primitives in `c:execute/4`.

  ## Selecting a runtime

  Implementations are keyed by a runtime tag (`:lua`, …). `execute/4`
  dispatches on that tag, so the resolver never names a concrete engine. The
  set of runtimes is closed and known at compile time, and is carried
  per-subscription (the `transform_runtime` attribute, whose `one_of` constraint
  derives from `runtimes/0`) so each route picks its language.
  """

  alias AshIntegration.Outbound.Delivery.Transform.Limits

  @typedoc "Source for the transform — script text today, possibly bytecode later."
  @type source :: binary()

  @typedoc "A JSON-serializable map (string/atom keys, JSON-safe values)."
  @type data :: map()

  @typedoc "Runtime-neutral execution limits."
  @type limits :: Limits.t()

  @typedoc """
  The outcome of running a transform:

    * `{:ok, map}` — deliver this descriptor
    * `{:ok, :skip}` — drop the event
    * `{:error, reason}` — the transform failed; the caller parks the delivery
  """
  @type result :: {:ok, data()} | {:ok, :skip} | {:error, String.t()}

  @doc """
  Run `source` against `event`, starting from the pre-seeded `defaults`,
  bounded by `limits`. See `t:result/0` for the contract.
  """
  @callback execute(source(), event :: data(), defaults :: data() | nil, limits()) :: result()

  @typedoc """
  The outcome of invoking a single signing callback:

    * `{:ok, {:defined, value}}` — the callback exists; `value` is its decoded return
    * `{:ok, :undefined}` — the source exposes no such callback (use the library default)
    * `{:error, reason}` — the callback raised, hit a limit, or the source failed
  """
  @type sign_result :: {:ok, {:defined, term()} | :undefined} | {:error, String.t()}

  @typedoc """
  A `call/2` the runtime hands the orchestrator: invoke the signing callback named
  `fname` against `ctx` on the already-compiled source. See `t:sign_result/0`.
  """
  @type sign_call :: (fname :: String.t(), ctx :: data() -> sign_result())

  @doc """
  Run a signing session: compile `source` ONCE, then invoke `orchestrate` with a
  `t:sign_call/0` that calls individual callbacks on that compiled state (no
  re-parse), all under a single resource budget. The orchestrator performs the
  keyed MAC between calls; the secret is never passed into the sandbox. Returns
  whatever `orchestrate` returns, or a classified `{:error, reason}` if the source
  fails to compile or the session crashes/times out.
  """
  @callback sign_session(source(), limits(), orchestrate :: (sign_call() -> term())) :: term()

  @doc "This runtime's config-driven default limits."
  @callback default_limits() :: limits()

  @doc """
  Cheap, side-effect-free check that `source` is well-formed enough to save
  (size/parse). Wired into the subscription's create/update validations (see
  `AshIntegration.Outbound.Delivery.Validations.TransformSource`). Optional — a
  runtime that can't pre-validate omits it and saves are accepted.
  """
  @callback validate(source()) :: :ok | {:error, String.t()}

  @optional_callbacks validate: 1

  @runtimes %{lua: AshIntegration.Outbound.Delivery.Transform.Runtime.Lua}

  @doc "The default transform runtime tag."
  @spec default_runtime() :: atom()
  def default_runtime, do: :lua

  @doc """
  Every known runtime tag — the single source of truth for the set of
  runtimes. The subscription's `transform_runtime` `one_of` constraint derives
  from this, so the persistable set and the dispatchable set can't drift.
  """
  @spec runtimes() :: [atom(), ...]
  def runtimes, do: Map.keys(@runtimes)

  @doc """
  Resolve a runtime tag to its implementing module. Raises for an unknown tag
  — the runtime set is closed and compile-time known, so an unknown tag is a
  programmer error, not user input.
  """
  @spec impl!(atom()) :: module()
  def impl!(runtime) do
    case Map.fetch(@runtimes, runtime) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unknown transform runtime: #{inspect(runtime)}"
    end
  end

  @doc """
  Run a transform on `runtime`, using that runtime's default limits.

  Dispatches to the runtime's `c:execute/4`. `defaults` is the pre-seeded
  delivery descriptor (or `nil` for no pre-seed).
  """
  @spec execute(atom(), source(), data(), data() | nil) :: result()
  def execute(runtime, source, event, defaults) do
    impl = impl!(runtime)
    impl.execute(source, event, defaults, impl.default_limits())
  end

  @doc """
  Run a signing session on `runtime`, using that runtime's default limits.
  Dispatches to the runtime's `c:sign_session/3`. See `t:sign_call/0`.
  """
  @spec sign_session(atom(), source(), (sign_call() -> term())) :: term()
  def sign_session(runtime, source, orchestrate) do
    impl = impl!(runtime)
    impl.sign_session(source, impl.default_limits(), orchestrate)
  end

  @doc "Validate `source` for `runtime` at save time, if the runtime supports it."
  @spec validate(atom(), source()) :: :ok | {:error, String.t()}
  def validate(runtime, source) do
    impl = impl!(runtime)

    # `function_exported?/3` reports false for a not-yet-loaded module, so make
    # sure it's loaded before probing for the optional callback.
    if Code.ensure_loaded?(impl) and function_exported?(impl, :validate, 1) do
      impl.validate(source)
    else
      :ok
    end
  end
end
