defmodule AshIntegration.Web.Outbound.Helpers do
  @moduledoc false
  # Generic, transport-neutral helpers shared across the outbound
  # LiveViews (Connection/Subscription/Event/Log): formatting, owner
  # display, and the transport-config form plumbing (auth/security subforms,
  # secret stripping, header/broker injection). The per-page form logic lives
  # in each page's own `*.Helpers` module.

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
  Read a paginated list for a dashboard index. A *forbidden* read degrades to an
  empty page (policies hide the list rather than crash it); any other error is
  re-raised, so a real load failure surfaces with a stacktrace instead of being
  swallowed into an empty table. The result responds to `.results` and is
  accepted by `page_meta/1`.
  """
  def read_page!(query, opts) do
    case Ash.read(query, opts) do
      {:ok, page} -> page
      {:error, %Ash.Error.Forbidden{}} -> %{results: [], offset: 0, limit: 20, count: 0}
      {:error, error} -> raise error
    end
  end

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

  def ensure_email_adapter_subform(form) do
    tc = form.forms[:transport_config]

    cond do
      is_nil(tc) ->
        form

      is_nil(tc.forms[:adapter]) ->
        AshPhoenix.Form.add_form(form, "form[transport_config][adapter]",
          params: %{"_union_type" => "smtp"}
        )

      true ->
        form
    end
  end

  # Signing applies to the HTTP and Kafka transports, so this is ensured for both.
  # Email carries no payload-signing scheme (nothing on the receiving end verifies
  # it), so the connection form skips it for email.
  def ensure_signing_subform(form) do
    tc = form.forms[:transport_config]

    cond do
      is_nil(tc) ->
        form

      is_nil(tc.forms[:signing]) ->
        AshPhoenix.Form.add_form(form, "form[transport_config][signing]",
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
          # Only touch a sub-map that's actually PRESENT: `auth` is HTTP-only and
          # `security` is Kafka-only, so defaulting an absent key (as Map.update/4
          # does) would inject a stray map the other transport rejects with
          # "no such input" — silently failing the whole save.
          |> update_if_present("signing", fn sig when is_map(sig) ->
            maybe_drop_blank(sig, "secret")
          end)
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
          # `adapter` is Email-only (the SMTP credential); update_if_present leaves
          # http/kafka params untouched since they carry no `adapter` key.
          |> update_if_present("adapter", fn adapter when is_map(adapter) ->
            maybe_drop_blank(adapter, "password")
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
        %{
          signing: signing_secret?(tc.signing),
          auth: http_auth_secret?(tc.auth)
        }

      %Ash.Union{type: :kafka, value: tc} ->
        %{
          signing: signing_secret?(tc.signing),
          sasl_password: kafka_sasl_password?(tc.security),
          auth: false
        }

      %Ash.Union{type: :email, value: tc} ->
        %{smtp_password: email_smtp_password?(tc.adapter), auth: false}

      _ ->
        %{signing: false, auth: false}
    end
  end

  defp signing_secret?(%Ash.Union{type: type, value: v}) when type in [:stripe, :custom],
    do: v.encrypted_secret != nil

  defp signing_secret?(_), do: false

  defp http_auth_secret?(%{type: :bearer_token, value: v}), do: v.encrypted_token != nil
  defp http_auth_secret?(%{type: :api_key, value: v}), do: v.encrypted_value != nil
  defp http_auth_secret?(%{type: :basic_auth, value: v}), do: v.encrypted_password != nil
  defp http_auth_secret?(_), do: false

  defp kafka_sasl_password?(%Ash.Union{type: type, value: sec}) when type in [:sasl, :sasl_tls],
    do: sec.encrypted_password != nil

  defp kafka_sasl_password?(_), do: false

  defp email_smtp_password?(%Ash.Union{type: :smtp, value: smtp}),
    do: smtp.encrypted_password != nil

  defp email_smtp_password?(_), do: false

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
