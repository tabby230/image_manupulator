defmodule ImageManipulatorWeb.MediaControllerTest do
  # Touches the shared settings file (the configured output directory), so it
  # must not run alongside the studio LiveView tests.
  use ImageManipulatorWeb.ConnCase, async: false

  alias ImageManipulator.{Paths, Settings, Workspace}

  setup do
    settings_file = Paths.settings_file()
    File.rm(settings_file)
    on_exit(fn -> File.rm(settings_file) end)
    :ok
  end

  defp external_dir do
    dir = Path.join(System.tmp_dir!(), "im_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "serves a thumbnail for an image saved outside the library", %{conn: conn} do
    dir = external_dir()
    target = Path.join(dir, "arrow_saved.jpg")
    File.cp!(Path.join(File.cwd!(), "test/fixtures/library/arrow.jpg"), target)

    # Exactly what "Save Image" does for a custom location: write the file and
    # remember the directory as the output directory.
    assert {:ok, _settings} = Settings.save(%{Settings.default() | output_dir: dir})

    assert Paths.readable?(target)

    response = get(conn, "/media/" <> Workspace.sign_media(target, width: 96))

    assert response.status == 200
    assert byte_size(response.resp_body) > 0
  end

  test "still refuses a token for a file outside every readable root", %{conn: conn} do
    outside =
      Path.join(System.tmp_dir!(), "im_outside_#{System.unique_integer([:positive])}.jpg")

    File.cp!(Path.join(File.cwd!(), "test/fixtures/library/arrow.jpg"), outside)
    on_exit(fn -> File.rm(outside) end)

    refute Paths.readable?(outside)

    response = get(conn, "/media/" <> Workspace.sign_media(outside, width: 96))

    assert response.status == 403
  end
end
