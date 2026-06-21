defmodule Example.Inbound.RecordPartnerRef do
  @moduledoc """
  Handler for the `record_partner_ref` command: store a partner's reference id on
  the product we announced. The handler resolves the target record (host logic)
  and returns a prepared changeset for the declared `(Product, :record_partner_ref)`.
  """
  use AshIntegration.Inbound.Declare.Handler

  @impl true
  def build_input(%{"product_id" => product_id, "ref" => ref}, ctx) do
    case Ash.get(Example.Catalog.Product, product_id, authorize?: false) do
      {:ok, product} ->
        {:ok,
         Ash.Changeset.for_update(product, :record_partner_ref, %{partner_ref: ref},
           actor: ctx.actor
         )}

      {:error, _} = error ->
        error
    end
  end

  def build_input(_payload, _ctx), do: {:error, "payload must carry product_id and ref"}

  @impl true
  def partition_key(%{"product_id" => product_id}), do: to_string(product_id)
  def partition_key(_), do: nil

  @impl true
  def example,
    do: %{"product_id" => "00000000-0000-0000-0000-000000000000", "ref" => "PARTNER-123"}
end
