defmodule ZaimuTomoWeb.Router do
  use ZaimuTomoWeb, :router

  import ZaimuTomoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ZaimuTomoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ZaimuTomoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # API routes
  scope "/api", ZaimuTomoWeb do
    pipe_through :api

    resources "/extracted_content", ExtractedContentController, only: [:index] do
      get "/:document_id", ExtractedContentController, :index
      get "/:document_id/latest", ExtractedContentController, :show
      post "/:id/retry", ExtractedContentController, :retry
      get "/", ExtractedContentController, :list
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:zaimu_tomo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ZaimuTomoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", ZaimuTomoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ZaimuTomoWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/documents", DocumentLive.Index, :index
      live "/documents/new", DocumentLive.Form, :new
      live "/documents/:id", DocumentLive.Show, :show
      live "/documents/:id/edit", DocumentLive.Form, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ZaimuTomoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ZaimuTomoWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
