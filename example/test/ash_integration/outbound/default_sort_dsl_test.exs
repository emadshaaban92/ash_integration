defmodule Example.Outbound.DefaultSortDslTest do
  @moduledoc """
  Regression guard for the DECLARED default sort on every injected browse action.

  `Ash.Resource.Preparation.Build.prepare/3` reads `opts[:options]`:

      def prepare(query, opts, _context), do: Ash.Query.build(query, opts[:options] || [])

  so a hand-built `{Ash.Resource.Preparation.Build, [sort: [id: :desc]]}` — the FLAT
  keyword shape — is a silent no-op: no sort, no error, no warning. Every transformer
  must nest its options (`Ash.Resource.Preparation.Builtins.build/1` builds that shape),
  or the `:index` / `:for_subscription` / `:parked` / `:for_connection` panes render an
  arbitrary slice.

  This asserts BOTH halves so the bug cannot come back through either door:

    * the built preparation carries `options:` (catches the flat shape at the DSL), and
    * `Ash.Query.for_read/4` actually puts the sort on the query (catches the effect).

  `:index` and `:for_subscription` also declare `keyset?: true, offset?: true` — an
  unordered paginated query can repeat or skip rows between pages, so this is a
  correctness guard, not a cosmetic one.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias Example.Outbound.{Connection, Event, EventDelivery, Log, Subscription}

  # {resource, action, args, expected sort}. `:parked` is ASCENDING on purpose —
  # oldest-first replay order.
  @browse_actions [
    {Connection, :index, %{}, [id: :desc]},
    {Event, :index, %{}, [id: :desc]},
    {EventDelivery, :index, %{}, [id: :desc]},
    {EventDelivery, :for_subscription, %{subscription_id: Ash.UUID.generate()}, [id: :desc]},
    {EventDelivery, :parked, %{connection_id: Ash.UUID.generate()}, [id: :asc]},
    {Log, :index, %{}, [id: :desc]},
    {Log, :for_subscription, %{subscription_id: Ash.UUID.generate()}, [id: :desc]},
    {Subscription, :index, %{}, [id: :desc]},
    {Subscription, :for_connection, %{connection_id: Ash.UUID.generate()}, [id: :desc]}
  ]

  for {resource, action, args, expected} <- @browse_actions do
    @resource resource
    @action action
    @args args
    @expected expected

    test "#{inspect(resource)}.#{action} declares a default sort of #{inspect(expected)}" do
      opts = build_preparation_options!(@resource, @action)

      assert Keyword.keyword?(opts),
             "#{inspect(@resource)}.#{@action}: Build preparation options must be a keyword list"

      # The load-bearing assertion. A flat `[sort: [...]]` has no `:options` key, so
      # `Build.prepare/3` falls through to `opts[:options] || []` and drops the sort.
      assert Keyword.has_key?(opts, :options),
             """
             #{inspect(@resource)}.#{@action}: Build preparation options are FLAT \
             (#{inspect(opts)}). `Ash.Resource.Preparation.Build` reads `opts[:options]`, \
             so this sort is silently dropped. Nest it: \
             `Ash.Resource.Preparation.Builtins.build(sort: #{inspect(@expected)})`.
             """

      assert opts[:options][:sort] == @expected
    end

    test "#{inspect(resource)}.#{action} puts #{inspect(expected)} on the built query" do
      query = Ash.Query.for_read(@resource, @action, @args, authorize?: false)

      assert query.sort == @expected,
             """
             #{inspect(@resource)}.#{@action}: expected query.sort == #{inspect(@expected)}, \
             got #{inspect(query.sort)}. An empty sort means the declared default was \
             dropped and the action returns rows in arbitrary order.
             """
    end
  end

  # The `Build` preparation's options, or a failure naming the action — a browse
  # action that lost its `prepare` entirely must fail here, not silently pass.
  defp build_preparation_options!(resource, action) do
    preparations =
      resource
      |> ResourceInfo.action(action)
      |> Map.fetch!(:preparations)

    Enum.find_value(preparations, fn
      %{preparation: {Ash.Resource.Preparation.Build, opts}} -> opts
      _ -> nil
    end) ||
      flunk(
        "#{inspect(resource)}.#{action} has no `Ash.Resource.Preparation.Build` preparation; " <>
          "got #{inspect(preparations)}"
      )
  end
end
