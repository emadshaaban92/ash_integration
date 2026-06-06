defmodule AshIntegration.Outbound.Delivery.Transform.Runtime do
  @moduledoc """
  The runtime-neutral seam between the resolver and a concrete transform
  engine.

  A transform is, conceptually, a pure function

      transform(event, defaults) -> result | :skip

  where `event` is the immutable event envelope and `defaults` is the
  transport-shaped delivery descriptor the resolver pre-seeds. The function
  returns the (possibly modified) descriptor to deliver, or `:skip` to drop
  the event.

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

  @doc "This runtime's config-driven default limits."
  @callback default_limits() :: limits()

  @doc """
  Cheap, side-effect-free check that `source` is well-formed enough to save
  (size/parse). Optional — a runtime that can't pre-validate omits it.
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
