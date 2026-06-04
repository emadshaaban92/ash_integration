defmodule Example.Outbound.ProjectProbe do
  @moduledoc """
  Test probe: records the batch size of each `project/3` call, so a test can
  prove dispatch runs `project` **once per (event_type, version) group** rather
  than once per event (the capture doc's batched-`project` win, open #2, that the
  relay realizes). Inert unless a test starts it.
  """
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc "Record the size of one `project/3` batch."
  def record(n) when is_integer(n), do: Agent.update(__MODULE__, &[n | &1])

  @doc "The recorded batch sizes, in call order."
  def batches, do: Agent.get(__MODULE__, &Enum.reverse(&1))

  @doc "True when the probe Agent is running (so the producer only records under test)."
  def running?, do: is_pid(Process.whereis(__MODULE__))
end
