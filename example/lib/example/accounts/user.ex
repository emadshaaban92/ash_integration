defmodule Example.Accounts.User do
  use Ash.Resource,
    domain: Example.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Example.Accounts.Token
      signing_secret Example.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender Example.Accounts.User.Senders.SendPasswordResetEmail
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      remember_me :remember_me
    end
  end

  postgres do
    table "users"
    repo Example.Repo
  end

  actions do
    default_accept [:email]
    defaults [:read, :destroy, create: :*, update: :*]

    read :index do
      argument :search, :string

      pagination keyset?: true, offset?: true, default_limit: 20, countable: :by_default

      prepare build(sort: [email: :asc])

      filter expr(
               if is_nil(^arg(:search)) do
                 true
               else
                 contains(email, ^arg(:search))
               end
             )
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end
  end

  calculations do
    calculate :display_name, :string, expr(email)
  end

  identities do
    identity :unique_email, [:email]
  end
end
