defmodule AshIntegration.QueryLogLevelTest do
  # async: false — mutates the global :ash_integration application env.
  use ExUnit.Case, async: false

  describe "query_log_level/0" do
    setup do
      original = Application.fetch_env(:ash_integration, :query_log_level)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:ash_integration, :query_log_level, value)
          :error -> Application.delete_env(:ash_integration, :query_log_level)
        end
      end)

      :ok
    end

    test "defaults to :debug (Ecto's own default — no behaviour change)" do
      Application.delete_env(:ash_integration, :query_log_level)
      assert AshIntegration.query_log_level() == :debug
    end

    test "false silences the internal poll/claim queries" do
      Application.put_env(:ash_integration, :query_log_level, false)
      assert AshIntegration.query_log_level() == false
    end

    test "any Logger level is passed straight through as Ecto's :log option" do
      Application.put_env(:ash_integration, :query_log_level, :info)
      assert AshIntegration.query_log_level() == :info
    end
  end
end
