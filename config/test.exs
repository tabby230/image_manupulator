import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :image_manipulator, ImageManipulatorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Z6yQ267NbzzcNaMs/Q0yLlfC/qLz5Hz8HsI058+OtY6btdO0AXeaHSZG0Ux74mi7",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Keep every test run hermetic: a throwaway library, workspace, exports
# directory and settings file under tmp/.
config :image_manipulator,
  library_roots: [%{id: "fixtures", label: "Test Fixtures", path: "test/fixtures/library"}],
  workspace_dir: "tmp/test/workspace",
  default_output_dir: "tmp/test/exports",
  settings_file: "tmp/test/settings.json"
