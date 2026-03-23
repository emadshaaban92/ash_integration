defmodule ExampleWeb.Router do
  use ExampleWeb, :router
  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers
  import AshIntegration.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  scope "/", ExampleWeb do
    pipe_through :browser

    get "/", PageController, :home
    auth_routes AuthController, Example.Accounts.User, path: "/auth"
    sign_out_route AuthController

    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{ExampleWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    ExampleWeb.AuthOverrides,
                    AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  ExampleWeb.AuthOverrides,
                  AshAuthentication.Phoenix.Overrides.DaisyUI
                ]
  end

  scope "/", ExampleWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes,
      on_mount: {ExampleWeb.LiveUserAuth, :live_user_required},
      layout: {ExampleWeb.Layouts, :dashboard} do
      ash_integration_dashboard("/integrations")
    end
  end

  if Application.compile_env(:example, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ExampleWeb.Telemetry
    end
  end
end
