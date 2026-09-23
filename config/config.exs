# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :image_manipulator,
  generators: [timestamp_type: :utc_datetime]

# ---------------------------------------------------------------------------
# ImageManipulator application configuration
# ---------------------------------------------------------------------------
# Every path below is resolved against :project_root (see
# ImageManipulator.Paths). Keep them relative so the project stays portable;
# override :project_root via the IM_PROJECT_ROOT environment variable.
#
# * :library_roots   - read-only folders that the app may browse. A folder
#                      browser can only ever see paths inside these roots.
# * :workspace_dir   - scratch space for uploads, previews and generated
#                      outputs. Kept out of the library so browsing stays clean.
# * :default_output_dir - where "Save Image" writes when a session has no
#                      explicit destination configured in Settings.
config :image_manipulator,
  library_roots: [
    %{id: "samples", label: "Sample Library", path: "priv/images"}
  ],
  workspace_dir: "priv/workspace",
  default_output_dir: "priv/exports",
  settings_file: "priv/settings.json",
  # Media tokens are handed to the browser so it can fetch bytes directly
  # from /media/:token. They are signed, so clients cannot invent paths.
  media_token_salt: "image-manipulator/media",
  # Guard rails for user supplied values.
  thumbnail_size_range: 48..512,
  jpg_quality_range: 5..100,
  max_upload_size: 25_000_000,
  session_ttl_hours: 24,
  stat_scan_limit: 5_000

# Configures the endpoint
config :image_manipulator, ImageManipulatorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ImageManipulatorWeb.ErrorHTML, json: ImageManipulatorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ImageManipulator.PubSub,
  live_view: [signing_salt: "EyZR/nVE"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  image_manipulator: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
