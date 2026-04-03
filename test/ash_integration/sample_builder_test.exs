defmodule AshIntegration.OutboundIntegrations.SampleBuilderTest do
  use ExUnit.Case, async: true

  alias AshIntegration.OutboundIntegrations.SampleBuilder

  @seller %{role: :seller}
  @admin %{role: :admin}

  describe "filter_unauthorized/2" do
    test "keeps relationships the actor can read" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: %AshIntegration.Test.PublicChild{id: "c1", value: "visible"},
        restricted_child: nil,
        public_items: []
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert filtered.public_child.id == "c1"
      assert filtered.public_child.value == "visible"
    end

    test "nils out relationships the actor cannot read" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: nil,
        restricted_child: %AshIntegration.Test.RestrictedChild{
          id: "r1",
          secret: "hidden"
        },
        public_items: []
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert filtered.restricted_child == nil
    end

    test "admin sees all relationships including restricted" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: %AshIntegration.Test.PublicChild{id: "c1", value: "visible"},
        restricted_child: %AshIntegration.Test.RestrictedChild{
          id: "r1",
          secret: "shown-to-admin"
        },
        public_items: []
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @admin)

      assert filtered.public_child.value == "visible"
      assert filtered.restricted_child.secret == "shown-to-admin"
    end

    test "recursively filters nested relationships" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: %AshIntegration.Test.PublicChild{
          id: "c1",
          value: "visible",
          nested_restricted: %AshIntegration.Test.RestrictedChild{
            id: "r2",
            secret: "nested-hidden"
          }
        },
        restricted_child: nil,
        public_items: []
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert filtered.public_child.value == "visible"
      assert filtered.public_child.nested_restricted == nil
    end

    test "admin sees nested restricted relationships" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: %AshIntegration.Test.PublicChild{
          id: "c1",
          value: "visible",
          nested_restricted: %AshIntegration.Test.RestrictedChild{
            id: "r2",
            secret: "nested-visible-to-admin"
          }
        },
        restricted_child: nil,
        public_items: []
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @admin)

      assert filtered.public_child.nested_restricted.secret == "nested-visible-to-admin"
    end

    test "filters each element in has_many lists" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: nil,
        restricted_child: nil,
        public_items: [
          %AshIntegration.Test.NestedPublic{
            id: "n1",
            label: "item-1",
            restricted: %AshIntegration.Test.RestrictedChild{
              id: "r3",
              secret: "list-hidden"
            }
          },
          %AshIntegration.Test.NestedPublic{
            id: "n2",
            label: "item-2",
            restricted: %AshIntegration.Test.RestrictedChild{
              id: "r4",
              secret: "also-hidden"
            }
          }
        ]
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert length(filtered.public_items) == 2
      assert Enum.at(filtered.public_items, 0).label == "item-1"
      assert Enum.at(filtered.public_items, 1).label == "item-2"
      assert Enum.at(filtered.public_items, 0).restricted == nil
      assert Enum.at(filtered.public_items, 1).restricted == nil
    end

    test "leaves nil relationships untouched" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: nil,
        restricted_child: nil,
        public_items: []
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert filtered.public_child == nil
      assert filtered.restricted_child == nil
    end

    test "leaves %Ash.NotLoaded{} relationships untouched" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: %Ash.NotLoaded{type: :relationship},
        restricted_child: %Ash.NotLoaded{type: :relationship},
        public_items: %Ash.NotLoaded{type: :relationship}
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert %Ash.NotLoaded{} = filtered.public_child
      assert %Ash.NotLoaded{} = filtered.restricted_child
    end

    test "leaves non-Ash structs untouched" do
      address = %AshIntegration.Test.EmbeddedAddress{
        street: "15 Tahrir St",
        city: "Cairo"
      }

      result = SampleBuilder.filter_unauthorized(address, @seller)

      assert result.street == "15 Tahrir St"
      assert result.city == "Cairo"
    end

    test "bug: accessing_from relationship nil'd even though actor can read through parent" do
      # AccessingFromOnly uses `authorize_if accessing_from(Parent, :accessing_from_child)`
      # — like a line item resource only accessible through its parent order or transfer.
      #
      # Without passing accessing_from context to Ash.can, the check has no relationship
      # context, so match?/3 returns false for all accessing_from policies. The resource
      # appears completely inaccessible, and the sample preview hides it — even though
      # the actor CAN read it through the parent relationship.
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: nil,
        restricted_child: nil,
        filtered_child: nil,
        public_items: [],
        accessing_from_child: [
          %AshIntegration.Test.AccessingFromOnly{id: "a1", detail: "accessible-through-parent"}
        ]
      }

      filtered = SampleBuilder.filter_unauthorized(sample, %{role: :seller})

      # This SHOULD be kept — we're traversing Parent.accessing_from_child,
      # which is exactly what the accessing_from policy authorizes.
      assert is_list(filtered.accessing_from_child)
      assert length(filtered.accessing_from_child) == 1
      assert hd(filtered.accessing_from_child).detail == "accessible-through-parent"
    end

    test "keeps relationships with data-dependent filter policies (conditional access)" do
      # FilteredByOwner uses `expr(owner_id == ^actor(:id))` — Ash can't resolve
      # the data field at strict-check, so it builds a query filter like
      # `owner_id == "me"`. This is NOT a false filter — it means conditional access.
      # The sample should conservatively keep the data.
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: nil,
        restricted_child: nil,
        filtered_child: %AshIntegration.Test.FilteredByOwner{
          id: "f1",
          name: "owned-data",
          owner_id: "someone-else"
        },
        public_items: [],
        accessing_from_child: [],
        no_auth_child: nil
      }

      filtered = SampleBuilder.filter_unauthorized(sample, %{id: "me", role: :seller})

      assert filtered.filtered_child != nil
      assert filtered.filtered_child.name == "owned-data"
    end

    test "keeps relationships on resources without an authorizer" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "test",
        public_child: nil,
        restricted_child: nil,
        filtered_child: nil,
        public_items: [],
        accessing_from_child: [],
        no_auth_child: %AshIntegration.Test.NoAuthorizerChild{
          id: "n1",
          info: "no-auth-data"
        }
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert filtered.no_auth_child != nil
      assert filtered.no_auth_child.info == "no-auth-data"
    end

    test "preserves base resource attributes regardless of role" do
      sample = %AshIntegration.Test.Parent{
        id: "p1",
        name: "important-data",
        public_child: nil,
        restricted_child: %AshIntegration.Test.RestrictedChild{
          id: "r1",
          secret: "hidden"
        },
        filtered_child: nil,
        public_items: [],
        accessing_from_child: [],
        no_auth_child: nil
      }

      filtered = SampleBuilder.filter_unauthorized(sample, @seller)

      assert filtered.id == "p1"
      assert filtered.name == "important-data"
      assert filtered.restricted_child == nil
    end
  end
end
