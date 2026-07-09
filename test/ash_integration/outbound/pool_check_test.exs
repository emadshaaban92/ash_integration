defmodule AshIntegration.Outbound.PoolCheckTest do
  # async: false — mutates the global :ash_integration application env (:repo,
  # :dispatch, :delivery).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshIntegration.Outbound.PoolCheck

  # A stand-in for a host `Ecto.Repo`: `PoolCheck` only calls `config/0` on it. Each
  # test picks the pool size by name so the module needs no runtime state.
  defmodule Pool2Repo do
    def config, do: [pool_size: 2]
  end

  defmodule Pool500Repo do
    def config, do: [pool_size: 500]
  end

  defmodule NoPoolRepo do
    def config, do: [database: "x"]
  end

  setup do
    saved =
      for key <- [:repo, :dispatch, :delivery], into: %{} do
        {key, Application.fetch_env(:ash_integration, key)}
      end

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:ash_integration, key, value)
        {key, :error} -> Application.delete_env(:ash_integration, key)
      end)
    end)

    :ok
  end

  describe "oversubscribed?/2" do
    test "true only when demand strictly exceeds the pool" do
      refute PoolCheck.oversubscribed?(10, 10)
      refute PoolCheck.oversubscribed?(9, 10)
      assert PoolCheck.oversubscribed?(11, 10)
    end
  end

  describe "pool_size/0" do
    test "reads the repo's configured pool_size" do
      Application.put_env(:ash_integration, :repo, Pool500Repo)
      assert PoolCheck.pool_size() == {:ok, 500}
    end

    test "falls back to DBConnection's default of 10 when unset" do
      Application.put_env(:ash_integration, :repo, NoPoolRepo)
      assert PoolCheck.pool_size() == {:ok, 10}
    end

    test "returns :error when no repo is configured" do
      Application.delete_env(:ash_integration, :repo)
      assert PoolCheck.pool_size() == :error
    end
  end

  describe "concurrency_demand/0" do
    test "sums the dispatch + delivery concurrency knobs plus the singleton overhead" do
      Application.put_env(:ash_integration, :dispatch, concurrency: 3)
      Application.put_env(:ash_integration, :delivery, concurrency: 7)

      # 3 (dispatch) + 7 (delivery) + 5 (producers/scheduler/health/retention)
      assert PoolCheck.concurrency_demand() == 15
    end
  end

  describe "warn_if_oversubscribed/0" do
    test "warns with an actionable message when the total exceeds the pool" do
      Application.put_env(:ash_integration, :repo, Pool2Repo)
      Application.put_env(:ash_integration, :dispatch, concurrency: 4)
      Application.put_env(:ash_integration, :delivery, concurrency: 4)

      log =
        capture_log(fn ->
          assert PoolCheck.warn_if_oversubscribed() == :ok
        end)

      assert log =~ "exceeds the repo connection pool"
      # demand = 4 + 4 + 5 = 13, pool = 2
      assert log =~ "(13)"
      assert log =~ "pool_size"
    end

    test "stays silent when the total fits inside the pool" do
      Application.put_env(:ash_integration, :repo, Pool500Repo)
      Application.put_env(:ash_integration, :dispatch, concurrency: 4)
      Application.put_env(:ash_integration, :delivery, concurrency: 4)

      log =
        capture_log(fn ->
          assert PoolCheck.warn_if_oversubscribed() == :ok
        end)

      refute log =~ "exceeds the repo connection pool"
    end

    test "is a no-op (no crash) when no repo is configured" do
      Application.delete_env(:ash_integration, :repo)
      Application.put_env(:ash_integration, :dispatch, concurrency: 999)
      Application.put_env(:ash_integration, :delivery, concurrency: 999)

      log =
        capture_log(fn ->
          assert PoolCheck.warn_if_oversubscribed() == :ok
        end)

      refute log =~ "exceeds the repo connection pool"
    end
  end
end
