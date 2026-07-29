defmodule AshIntegration.Outbound.Delivery.Transform.Runtime.Lua.DatetimeAPI do
  @moduledoc """
  The built-in `datetime` host API exposed into the Lua transform sandbox.

  Rendering a timestamp in a consumer's local time is a **per-subscription**
  decision: the same canonical event is delivered to many consumers, and each may
  want a different zone. Baking a pre-converted string into the event data at the
  producer takes that choice away from every other consumer, and a hardcoded
  `+02:00` in a transform is wrong for half the year in any DST region. This API
  keeps the choice in the transform:

      -- ISO-8601, re-rendered with the zone's offset for that instant
      datetime.to_zone("2024-06-15T10:30:00Z", "Africa/Cairo")
      --> "2024-06-15T13:30:00+03:00"

      -- `Calendar.strftime/3`-style formatting, in that zone
      datetime.format("2024-06-15T10:30:00Z", "Africa/Cairo", "%Y-%m-%d %H:%M")
      --> "2024-06-15 13:30"

  Both take an ISO-8601 timestamp **with a UTC offset** and an IANA zone name.
  `event.created_at` is always in that shape — `AshIntegration.Outbound.Wire.Envelope`
  normalizes it from the event's `DateTime`. A timestamp pulled out of `event.data`
  is only as good as its producer, which is why a missing offset raises (below)
  rather than being read as UTC.

  This is deliberately **not a clock**: it converts a timestamp the script already
  holds and exposes no "now". The sandbox stays deterministic — the same event
  re-run through `reprocess` renders the same string.

  ## Which time-zone database

  Zones resolve through whatever `Calendar.TimeZoneDatabase` the **host
  application** has configured (`config :elixir, :time_zone_database, …`).
  AshIntegration deliberately ships none — pinning `tzdata` or `tz` in a library
  forces that choice (and its update cadence) onto every host.

  ## Failures raise, they never fudge

  A silently-wrong timestamp on a wire is worse than a parked delivery an
  operator can see and fix, so every failure mode raises a Lua error naming the
  cause — which parks the delivery with that message in `last_error`:

  - **no time-zone database configured** — `DateTime.shift_zone/2` answers
    `{:error, :utc_only_time_zone_database}`; we say so by name rather than
    quietly emitting UTC.
  - **unknown zone** — a typo'd or non-IANA name.
  - **unparseable timestamp**, including one with **no UTC offset** (`Z` or
    `±HH:MM`): a bare wall-clock string has no single instant to convert, and
    guessing UTC would be exactly the silent wrongness this API exists to avoid.
  - **unknown `strftime` directive** in the format string.

  ## Purity

  This is pure computation over its arguments — no I/O, no network, no
  filesystem — which is the bar every host API must clear (see
  `AshIntegration.Outbound.Delivery.Transform.Runtime.Lua`). It reads process/
  application state only through the host's configured time-zone database.
  """

  use Lua.API, scope: "datetime"

  @doc """
  `datetime.to_zone(iso8601, tz)` — the same instant, rendered as ISO-8601 with
  `tz`'s offset for that instant (so DST is applied, not assumed).
  """
  deflua to_zone(iso8601, zone) do
    case shift(iso8601, zone) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, message} -> runtime_exception!(message)
    end
  end

  @doc """
  `datetime.format(iso8601, tz, fmt)` — the same instant in `tz`, formatted with
  `Calendar.strftime/3` directives (`%Y-%m-%d %H:%M:%S`, `%z`, `%Z`, …).
  """
  deflua format(iso8601, zone, fmt) do
    with {:ok, datetime} <- shift(iso8601, zone),
         {:ok, formatted} <- strftime(datetime, fmt) do
      formatted
    else
      {:error, message} -> runtime_exception!(message)
    end
  end

  defp shift(iso8601, zone) when is_binary(iso8601) and is_binary(zone) do
    with {:ok, datetime} <- parse(iso8601) do
      case DateTime.shift_zone(datetime, zone) do
        {:ok, shifted} ->
          {:ok, shifted}

        {:error, :utc_only_time_zone_database} ->
          {:error,
           "cannot convert to #{inspect(zone)}: utc_only_time_zone_database — the host " <>
             "application has configured no Calendar time-zone database " <>
             "(config :elixir, :time_zone_database, Tz.TimeZoneDatabase or Tzdata.TimeZoneDatabase)"}

        {:error, :time_zone_not_found} ->
          {:error, "unknown time zone #{inspect(zone)}"}

        {:error, reason} ->
          {:error, "cannot convert to #{inspect(zone)}: #{inspect(reason)}"}
      end
    end
  end

  defp shift(iso8601, zone) when is_binary(iso8601),
    do: {:error, "expected a time zone name string, got: #{inspect(zone)}"}

  defp shift(iso8601, _zone),
    do: {:error, "expected an ISO-8601 timestamp string, got: #{inspect(iso8601)}"}

  defp parse(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, :missing_offset} ->
        {:error,
         "#{inspect(iso8601)} has no UTC offset, so it names no single instant — " <>
           "pass an ISO-8601 timestamp ending in \"Z\" or \"+HH:MM\""}

      {:error, reason} ->
        {:error, "#{inspect(iso8601)} is not a valid ISO-8601 timestamp: #{inspect(reason)}"}
    end
  end

  defp strftime(datetime, fmt) when is_binary(fmt) do
    {:ok, Calendar.strftime(datetime, fmt)}
  rescue
    e -> {:error, "invalid format string #{inspect(fmt)}: #{Exception.message(e)}"}
  end

  defp strftime(_datetime, fmt),
    do: {:error, "expected a format string, got: #{inspect(fmt)}"}
end
