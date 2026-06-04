defmodule AshIntegration.Web.Outbound.Helpers do
  @moduledoc false
  # Generic, transport-neutral helpers shared across the outbound
  # LiveViews (Connection/Subscription/Event/Log): formatting, owner
  # display, and the transport-config form plumbing (auth/security subforms,
  # secret stripping, header/broker injection). The per-page form logic lives
  # in each page's own `*.Helpers` module.

  require Ash.Query

  # ── Index (all) page plumbing, shared by the Event/Delivery/Log browsers ────

  @doc "Collapse blank query params (nil / \"\") to nil."
  def presence(nil), do: nil
  def presence(""), do: nil
  def presence(value), do: value

  @doc "The sorted list of declared event-type names (the derived catalog)."
  def event_types do
    AshIntegration.Outbound.Declare.Registry.catalog() |> Map.keys() |> Enum.sort()
  end

  @doc "Normalize an Ash page (or fallback map) to the `pagination` component shape."
  def page_meta(page),
    do: %{offset: page.offset || 0, limit: page.limit || 20, count: page.count}

  @doc "An empty `page_meta` for the initial render."
  def empty_page, do: %{offset: 0, limit: 20, count: 0}

  @doc """
  Read the connections visible to `actor` for the filter dropdowns. No-bang:
  degrades to `[]` (an empty dropdown) rather than crashing the page.
  """
  def list_connections(actor) do
    case AshIntegration.connection_resource()
         |> Ash.Query.for_read(:index, %{}, actor: actor)
         |> Ash.read(actor: actor, page: false) do
      {:ok, %{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  end

  @doc """
  Build a filtered index path: `base_path() <> suffix`, appending only the
  non-blank `kw` params as a query string (drops nil/""/0).
  """
  def filtered_path(suffix, kw) do
    query =
      kw
      |> Enum.reject(fn {_k, v} -> v in [nil, "", 0, "0"] end)
      |> URI.encode_query()

    base = AshIntegration.Web.base_path() <> suffix
    if query == "", do: base, else: base <> "?" <> query
  end

  @doc """
  Whether `actor` may perform an action, for UI gating. **Fail-closed**: any error
  (or an undeterminable check) renders as `false`, so we never show an action the
  host's policies would reject. `subject` is whatever `Ash.can?/2` accepts — most
  often `{resource, :action}` (e.g. create) or `{record, :action}` (e.g. update,
  destroy, a named state-transition).

  Hiding a control is cosmetic; the underlying Ash action (run with the same actor)
  is the real enforcement. For the few UI-triggered operations that run under system
  authority (reprocess/redispatch), call this in the handler too, to enforce.
  """
  def can?(subject, actor) do
    Ash.can?(subject, actor)
  rescue
    _ -> false
  end

  def humanize(value) when is_atom(value), do: humanize(Atom.to_string(value))

  def humanize(value) when is_binary(value) do
    value
    |> Phoenix.Naming.humanize()
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize(value), do: to_string(value)

  def format_datetime(value, format \\ :short)

  def format_datetime(%DateTime{} = dt, format) do
    case format do
      :short -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      :long -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
    end
  end

  def format_datetime(_, _format), do: "—"

  def parse_int(nil, default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(val, _default) when is_integer(val), do: val

  def owner_name(%{owner: %{display_name: dn}}) when is_binary(dn), do: dn
  def owner_name(%{owner: %{name: name}}) when is_binary(name), do: name
  def owner_name(%{owner: %{email: email}}), do: to_string(email)
  def owner_name(_), do: "—"

  def ensure_auth_subform(form) do
    tc = form.forms[:transport_config]

    cond do
      is_nil(tc) ->
        form

      is_nil(tc.forms[:auth]) ->
        AshPhoenix.Form.add_form(form, "form[transport_config][auth]",
          params: %{"_union_type" => "none"}
        )

      true ->
        form
    end
  end

  def ensure_security_subform(form) do
    tc = form.forms[:transport_config]

    cond do
      is_nil(tc) ->
        form

      is_nil(tc.forms[:security]) ->
        AshPhoenix.Form.add_form(form, "form[transport_config][security]",
          params: %{"_union_type" => "none"}
        )

      true ->
        form
    end
  end

  @encrypted_auth_fields ["token", "value", "password"]

  def strip_blank_secrets(params) do
    case get_in(params, ["transport_config"]) do
      tc when is_map(tc) ->
        tc =
          tc
          |> maybe_drop_blank("signing_secret")
          # Only touch a sub-map that's actually PRESENT: `auth` is HTTP-only and
          # `security` is Kafka-only, so defaulting an absent key (as Map.update/4
          # does) would inject a stray map the other transport rejects with
          # "no such input" — silently failing the whole save.
          |> update_if_present("auth", fn auth when is_map(auth) ->
            Enum.reduce(@encrypted_auth_fields, auth, &maybe_drop_blank(&2, &1))
          end)
          |> update_if_present("security", fn sec when is_map(sec) ->
            sec
            |> maybe_drop_blank("password")
            |> maybe_drop_blank("token")
            |> maybe_drop_blank("client_cert_pem")
            |> maybe_drop_blank("client_key_pem")
          end)

        put_in(params, ["transport_config"], tc)

      _ ->
        params
    end
  end

  defp maybe_drop_blank(map, key) do
    case Map.get(map, key) do
      val when val in [nil, ""] -> Map.delete(map, key)
      _ -> map
    end
  end

  # Apply `fun` to `map[key]` only when the key exists — never inserts it.
  defp update_if_present(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end

  def detect_existing_secrets(record) do
    case record.transport_config do
      %Ash.Union{type: :http, value: tc} ->
        auth_secret =
          case tc.auth do
            %{type: :bearer_token, value: v} -> v.encrypted_token != nil
            %{type: :api_key, value: v} -> v.encrypted_value != nil
            %{type: :basic_auth, value: v} -> v.encrypted_password != nil
            _ -> false
          end

        %{
          signing_secret: tc.encrypted_signing_secret != nil,
          auth: auth_secret
        }

      %Ash.Union{type: :kafka, value: tc} ->
        sasl_password =
          case tc.security do
            %Ash.Union{type: type, value: sec} when type in [:sasl, :sasl_tls] ->
              sec.encrypted_password != nil

            _ ->
              false
          end

        %{
          signing_secret: tc.encrypted_signing_secret != nil,
          sasl_password: sasl_password,
          auth: false
        }

      _ ->
        %{signing_secret: false, auth: false}
    end
  end

  def inject_headers_map(params) do
    params
    |> inject_kv_headers(["transport_config", "headers"])
    |> inject_kv_headers(["transport_config", "headers_kafka"])
    |> inject_brokers_list()
  end

  defp inject_kv_headers(params, path) do
    case get_in(params, path) do
      raw when is_map(raw) ->
        headers_map =
          raw
          |> Map.values()
          |> Enum.reject(fn entry -> entry["key"] == "" end)
          |> Map.new(fn entry -> {entry["key"], entry["value"] || ""} end)

        # kafka_headers get written to the "headers" transport_config field
        target_path =
          case List.last(path) do
            "headers_kafka" -> List.replace_at(path, -1, "headers")
            _ -> path
          end

        put_in(params, target_path, headers_map)

      _ ->
        params
    end
  end

  defp inject_brokers_list(params) do
    case get_in(params, ["transport_config", "brokers"]) do
      raw when is_map(raw) ->
        brokers =
          raw
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {_, v} -> v end)
          |> Enum.reject(&(&1 == ""))

        put_in(params, ["transport_config", "brokers"], brokers)

      _ ->
        params
    end
  end
end
