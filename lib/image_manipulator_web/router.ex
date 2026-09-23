defmodule ImageManipulatorWeb.Router do
  use ImageManipulatorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ImageManipulatorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ImageManipulatorWeb do
    pipe_through :browser

    live "/", StudioLive, :index
    get "/media/:token", MediaController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", ImageManipulatorWeb do
  #   pipe_through :api
  # end
end
