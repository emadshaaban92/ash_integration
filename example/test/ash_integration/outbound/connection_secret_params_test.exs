defmodule Example.Outbound.ConnectionSecretParamsTest do
  @moduledoc """
  Regression tests for `AshIntegration.Web.Outbound.Helpers.strip_blank_secrets/1`.

  It must drop blank secret params (so they don't overwrite stored encrypted
  values on update) WITHOUT inserting a transport's secret sub-map into the other
  transport's config — `auth` is HTTP-only and `security` is Kafka-only, and a
  stray key is rejected by AshPhoenix as "no such input", silently failing the save.
  """
  use ExUnit.Case, async: true

  alias AshIntegration.Web.Outbound.Helpers

  test "an HTTP config never gains a stray `security` key" do
    params = %{
      "transport_config" => %{
        "_union_type" => "http",
        "auth" => %{"_union_type" => "none"},
        "base_url" => "https://example.com",
        "signing" => %{"_union_type" => "stripe", "secret" => "secret"}
      }
    }

    tc = Helpers.strip_blank_secrets(params)["transport_config"]

    refute Map.has_key?(tc, "security")
    assert tc["signing"]["secret"] == "secret"
  end

  test "a Kafka config never gains a stray `auth` key" do
    params = %{
      "transport_config" => %{
        "_union_type" => "kafka",
        "security" => %{"_union_type" => "none"},
        "topic" => "events"
      }
    }

    tc = Helpers.strip_blank_secrets(params)["transport_config"]

    refute Map.has_key?(tc, "auth")
  end

  test "blank secrets are dropped; present ones are kept" do
    params = %{
      "transport_config" => %{
        "_union_type" => "http",
        "signing" => %{"_union_type" => "stripe", "secret" => ""},
        "auth" => %{"_union_type" => "bearer_token", "token" => ""}
      }
    }

    tc = Helpers.strip_blank_secrets(params)["transport_config"]

    refute Map.has_key?(tc["signing"], "secret")
    refute Map.has_key?(tc["auth"], "token")
  end

  test "a blank Email SMTP password is dropped so it doesn't overwrite the stored one" do
    params = %{
      "transport_config" => %{
        "_union_type" => "email",
        "from" => "bot@acme.com",
        "adapter" => %{"_union_type" => "smtp", "relay" => "smtp.acme.com", "password" => ""}
      }
    }

    tc = Helpers.strip_blank_secrets(params)["transport_config"]

    refute Map.has_key?(tc["adapter"], "password")
    assert tc["adapter"]["relay"] == "smtp.acme.com"
  end

  test "a present Email SMTP password is kept" do
    params = %{
      "transport_config" => %{
        "_union_type" => "email",
        "adapter" => %{
          "_union_type" => "smtp",
          "relay" => "smtp.acme.com",
          "password" => "hunter2"
        }
      }
    }

    tc = Helpers.strip_blank_secrets(params)["transport_config"]

    assert tc["adapter"]["password"] == "hunter2"
  end

  test "a blank HTTP OAuth2 client_secret is dropped; a present one is kept" do
    blank = %{
      "transport_config" => %{
        "_union_type" => "http",
        "base_url" => "https://api.example.com",
        "auth" => %{"_union_type" => "oauth2_client_credentials", "client_secret" => ""}
      }
    }

    refute Map.has_key?(
             Helpers.strip_blank_secrets(blank)["transport_config"]["auth"],
             "client_secret"
           )

    present = put_in(blank, ["transport_config", "auth", "client_secret"], "shh")
    tc = Helpers.strip_blank_secrets(present)["transport_config"]
    assert tc["auth"]["client_secret"] == "shh"
  end

  test "a blank MsGraph OAuth2 client_secret (nested under adapter) is dropped" do
    params = %{
      "transport_config" => %{
        "_union_type" => "email",
        "from" => "bot@acme.com",
        "adapter" => %{
          "_union_type" => "ms_graph",
          "oauth2" => %{
            "token_url" => "https://login.test/token",
            "client_id" => "cid",
            "client_secret" => ""
          }
        }
      }
    }

    oauth2 = Helpers.strip_blank_secrets(params)["transport_config"]["adapter"]["oauth2"]

    refute Map.has_key?(oauth2, "client_secret")
    assert oauth2["client_id"] == "cid"
  end

  test "a present MsGraph OAuth2 client_secret is kept" do
    params = %{
      "transport_config" => %{
        "_union_type" => "email",
        "adapter" => %{
          "_union_type" => "ms_graph",
          "oauth2" => %{"client_secret" => "graphsecret"}
        }
      }
    }

    tc = Helpers.strip_blank_secrets(params)["transport_config"]
    assert tc["adapter"]["oauth2"]["client_secret"] == "graphsecret"
  end
end
