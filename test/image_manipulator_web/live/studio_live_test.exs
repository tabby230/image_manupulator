defmodule ImageManipulatorWeb.StudioLiveTest do
  use ImageManipulatorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ImageManipulator.Workspace

  setup do
    session = Workspace.new_session()
    src = Path.join(File.cwd!(), "test/fixtures/library/arrow.jpg")

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"studio_sid" => session.id})

    {:ok, conn: conn, session: session, src: src}
  end

  describe "rotation controls" do
    test "render with the param key, never the collision-prone phx-value-value key",
         %{conn: conn, session: session, src: src} do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, lv, _html} = live(conn, "/")
      html = render(lv)

      refute html =~ "phx-value-value"

      stage_buttons =
        Regex.scan(~r/<button[^>]*phx-click="rotate"[^>]*>/, html)
        |> Enum.map(&List.first/1)
        |> Enum.join(" ")

      assert stage_buttons =~ ~s(phx-value-param="-90")
      assert stage_buttons =~ ~s(phx-value-param="90")

      rotation_segments =
        Regex.scan(~r/<button[^>]*phx-click="set_rotation"[^>]*>/, html)
        |> Enum.map(&List.first/1)
        |> Enum.join(" ")

      assert length(Regex.scan(~r/phx-click="set_rotation"/, html)) == 4

      for degrees <- ["0", "90", "180", "270"] do
        assert rotation_segments =~ ~s(phx-value-param="#{degrees}")
      end
    end

    for {event, param, selector, expected} <- [
          {"rotate", "-90", "button.btn--icon[phx-value-param=\"-90\"]", 270},
          {"rotate", "90", "button.btn--icon[phx-value-param=\"90\"]", 90},
          {"set_rotation", "0", "button.seg__item[phx-value-param=\"0\"]", 0},
          {"set_rotation", "90", "button.seg__item[phx-value-param=\"90\"]", 90},
          {"set_rotation", "180", "button.seg__item[phx-value-param=\"180\"]", 180},
          {"set_rotation", "270", "button.seg__item[phx-value-param=\"270\"]", 270}
        ] do
      test "clicking #{event} #{param} rotates to #{expected} without error",
           %{conn: conn, session: session, src: src} do
        File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

        {:ok, lv, _html} = live(conn, "/")

        element(lv, unquote(selector)) |> render_click()

        html = render(lv)

        refute html =~ "Unsupported rotation"
        assert html =~ ~s(ops__value">#{unquote(expected)}°</span>)
      end
    end
  end

  describe "format controls" do
    test "render with the param key and all three targets", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, lv, _html} = live(conn, "/")
      html = render(lv)

      refute html =~ "phx-value-value"

      format_segments =
        Regex.scan(~r/<button[^>]*phx-click="set_format"[^>]*>/, html)
        |> Enum.map(&List.first/1)
        |> Enum.join(" ")

      assert format_segments =~ ~s(phx-value-param="png")
      assert format_segments =~ ~s(phx-value-param="webp")
      assert format_segments =~ ~s(phx-value-param="jpg")
      assert html =~ "Convert Format"
    end

    for {param, expected_label, expected_name} <- [
          {"png", "PNG", "arrow_edited.png"},
          {"webp", "WebP", "arrow_edited.webp"}
        ] do
      test "selecting #{param} updates label and suggested save name", %{
        conn: conn,
        session: session,
        src: src
      } do
        File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

        {:ok, lv, _html} = live(conn, "/")

        element(lv, ~s(button.seg__item[phx-value-param="#{unquote(param)}"])) |> render_click()

        html = render(lv)

        refute html =~ "Unsupported output format"
        assert html =~ ~s(ops__value">#{unquote(expected_label)}</span>)
        assert html =~ ~s(value="#{unquote(expected_name)}")
      end
    end

    test "png disables compression while webp keeps it enabled", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, lv, _html} = live(conn, "/")

      element(lv, ~s(button.seg__item[phx-value-param="png"])) |> render_click()
      html = render_async(lv)

      assert html =~ "PNG is lossless"

      for param <- ["low", "medium", "high"] do
        [[seg]] = Regex.scan(~r/<button[^>]*phx-value-param="#{param}"[^>]*>/, html)
        assert seg =~ "disabled"
      end

      element(lv, ~s(button.seg__item[phx-value-param="webp"])) |> render_click()
      html = render_async(lv)

      refute html =~ "PNG is lossless"

      [[low]] = Regex.scan(~r/<button[^>]*phx-value-param="low"[^>]*>/, html)
      refute low =~ "disabled"
    end

    test "apply still applies a webp pipeline end to end", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, lv, _html} = live(conn, "/")

      element(lv, ~s(button.seg__item[phx-value-param="webp"])) |> render_click()
      render_async(lv)

      element(lv, ~s(button[phx-click="apply_changes"])) |> render_click()

      html = render_async(lv)

      refute html =~ "Unable to process image"
      assert html =~ "Convert to WebP"
    end
  end

  describe "zoom controls" do
    test "zoom in/out adjust the stage --zoom value within bounds", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, lv, _html} = live(conn, "/")
      html = render(lv)

      assert html =~ ~s("--zoom: 1.0")
      assert html =~ ~s(1:1)

      element(lv, ~s(button[phx-value-param="in"])) |> render_click()

      html = render(lv)
      assert html =~ ~s("--zoom: 1.25")
      assert html =~ ~s(125%)

      # Repeated zoom-in clamps at 3.0
      for _ <- 1..20, do: element(lv, ~s(button[phx-value-param="in"])) |> render_click()
      assert render(lv) =~ ~s("--zoom: 3.0")

      # Zoom out steps back down and clamps at 0.25
      element(lv, ~s(button[phx-value-param="out"])) |> render_click()
      assert render(lv) =~ ~s("--zoom: 2.4")

      for _ <- 1..30, do: element(lv, ~s(button[phx-value-param="out"])) |> render_click()
      assert render(lv) =~ ~s("--zoom: 0.25")

      # 1:1 button returns to baseline
      element(lv, ~s(button[phx-value-param="actual"])) |> render_click()
      html = render(lv)
      assert html =~ ~s("--zoom: 1.0")
      assert html =~ ~s(1:1)
    end

    test "fullscreen button dispatches app:fullscreen to the stage viewport", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, lv, _html} = live(conn, "/")
      html = render(lv)

      [[btn]] = Regex.scan(~r/<button[^>]*data-stage-action="fullscreen"[^>]*>/, html)
      assert btn =~ ~s(phx-click)
      assert btn =~ "app:fullscreen"
      assert btn =~ "#stage-viewport"
      refute btn =~ ~s(phx-click="toggle_fullscreen")
    end
  end

  describe "stage drag-and-drop" do
    test "stage viewport is a drop target for the same upload ref as the sidebar form", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, _lv, html} = live(conn, "/")

      sidebar_ref =
        Regex.scan(
          ~r/<form[^>]*id="upload-form"[^>]*phx-drop-target="([^"]+)"/,
          html
        )
        |> List.first()
        |> List.last()

      stage_viewport =
        Regex.scan(~r/<div class="stage__viewport"[^>]*>/, html)
        |> List.first()
        |> List.first()

      assert stage_viewport =~ ~s(phx-drop-target="#{sidebar_ref}")
    end

    test "stage drag-over visual class exists in the served CSS" do
      css = File.read!(Path.join(File.cwd!(), "priv/static/assets/app.css"))
      assert css =~ "stage__viewport--drag-over"
    end
  end

  describe "auto-upload flow" do
    test "selecting an image stores it, lists it, and renders it in the preview", %{
      conn: conn,
      src: src
    } do
      {:ok, lv, _html} = live(conn, "/")

      upload =
        file_input(lv, "#upload-form", :images, [
          %{name: "arrow.jpg", content: File.read!(src), type: "image/jpeg"}
        ])

      html = render_upload(upload, "arrow.jpg")

      assert html =~ "arrow.jpg"
      assert html =~ ~s(class="stage__img")
      assert html =~ ~r/src="\/media\/[^"]+"/s
    end

    test "non-image files are rejected and never reach the image list", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, "/")

      upload =
        file_input(lv, "#upload-form", :images, [
          %{name: "clip.mp4", content: "not a real video", type: "video/mp4"}
        ])

      assert {:error, _} = render_upload(upload, "clip.mp4")

      html = render(lv)

      refute html =~ ~r/<div class="card-wrapper"/
      refute html =~ ~s(class="stage__img")
    end
  end

  describe "save as panel" do
    # Every test starts from a pristine settings file so "first use" defaults
    # hold and the remembered-path persistence cannot leak between tests.
    setup do
      settings_file = ImageManipulator.Paths.settings_file()
      File.rm(settings_file)
      on_exit(fn -> File.rm(settings_file) end)
      :ok
    end

    test "renders beside the operations panel in the ops column", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ ~s(id="save-panel")
      assert html =~ "Save As"

      assert html =~
               ~r/<div class="ops-column">.*?<section class="panel ops">.*?id="save-panel"/s
    end

    # Uploads arrow.jpg, turns on invert (a pending operation) and applies it,
    # so save_source finds a current_output and the Save button is enabled.
    defp prepare_savable(lv, src) do
      upload =
        file_input(lv, "#upload-form", :images, [
          %{name: "arrow.jpg", content: File.read!(src), type: "image/jpeg"}
        ])

      render_upload(upload, "arrow.jpg")
      render_async(lv)

      element(lv, "button.switch__control") |> render_click()
      render_async(lv)

      element(lv, ~s(button[phx-click="apply_changes"])) |> render_click()
      render_async(lv)
    end

    defp save_location_value(lv) do
      html = render(lv)

      case Regex.run(~r/<input[^>]*id="save-location"[^>]*>/, html) do
        [tag] ->
          case Regex.run(~r/value="([^"]*)"/, tag) do
            [_, value] -> value
            _ -> ""
          end

        _ ->
          nil
      end
    end

    test "saves into the location entered in the field when Save Image is clicked", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))
      {:ok, lv, _html} = live(conn, "/")
      prepare_savable(lv, src)

      custom_dir = Path.join(session.root, "custom")
      target = Path.join(custom_dir, "arrow_custom.jpg")

      form(lv, "#save-panel form", %{"file_name" => "arrow_custom.jpg", "location" => custom_dir})
      |> render_submit()

      assert File.regular?(target)

      # The same save did *not* silently fall back to the pre-filled default
      # (settings output dir) or the session outputs folder.
      default_dir = ImageManipulator.Paths.exports()
      refute File.regular?(Path.join(default_dir, "arrow_custom.jpg"))
      refute File.regular?(Path.join(session.outputs, "arrow_custom.jpg"))
    end

    test "an edited location is used on the next save (no stale cached path)", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))
      {:ok, lv, _html} = live(conn, "/")
      prepare_savable(lv, src)

      first_dir = Path.join(session.root, "first")

      form(lv, "#save-panel form", %{"file_name" => "arrow_save.jpg", "location" => first_dir})
      |> render_submit()

      assert File.regular?(Path.join(first_dir, "arrow_save.jpg"))

      second_dir = Path.join(session.root, "second")

      form(lv, "#save-panel form", %{"file_name" => "arrow_save.jpg", "location" => second_dir})
      |> render_submit()

      assert File.regular?(Path.join(second_dir, "arrow_save.jpg"))

      # The panel now reflects the path that was actually used.
      assert save_location_value(lv) == second_dir
    end

    test "changing then clearing the location field clears it instead of keeping a stale value",
         %{conn: conn, session: session, src: src} do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))
      {:ok, lv, _html} = live(conn, "/")
      prepare_savable(lv, src)

      custom_dir = Path.join(session.root, "custom")

      element(lv, "#save-panel form")
      |> render_change(%{"file_name" => "arrow.jpg", "location" => custom_dir})

      assert save_location_value(lv) == custom_dir

      # Submit an empty location: it must be treated as cleared, never as
      # "keep the previously typed path".
      element(lv, "#save-panel form")
      |> render_change(%{"file_name" => "arrow.jpg", "location" => ""})

      assert save_location_value(lv) == ""

      # And saving with the cleared field falls back to the configured default.
      form(lv, "#save-panel form", %{"file_name" => "arrow_cleared.jpg", "location" => ""})
      |> render_submit()

      assert File.regular?(Path.join(ImageManipulator.Paths.exports(), "arrow_cleared.jpg"))
    end

    # Regression: "Save Image" may write to a directory outside every library
    # root - the remembered location becomes the configured output directory.
    # Thumbnails for those files must still be served, not answered with a 403
    # the browser paints as a broken image.
    test "a thumbnail is served for an image saved outside the library", %{
      conn: conn,
      session: session,
      src: src
    } do
      File.cp!(src, Path.join(session.uploads, "arrow.jpg"))
      {:ok, lv, _html} = live(conn, "/")
      prepare_savable(lv, src)

      external_dir =
        Path.join(System.tmp_dir!(), "im_saved_#{System.unique_integer([:positive])}")

      File.mkdir_p!(external_dir)
      on_exit(fn -> File.rm_rf(external_dir) end)

      form(lv, "#save-panel form", %{"file_name" => "arrow_saved.jpg", "location" => external_dir})
      |> render_submit()

      saved = Path.join(external_dir, "arrow_saved.jpg")
      assert File.regular?(saved)

      # The save remembered the directory as the output directory, and media for
      # files written there is authorised rather than rejected as "outside the
      # configured library".
      assert ImageManipulator.Settings.output_dir() == external_dir
      assert ImageManipulator.Paths.readable?(saved)

      # My Images must build its thumbnail from the stored path with the same
      # signed `/media/:token` source the Home images list uses.
      html = element(lv, ~s(button[phx-value-view="my_images"])) |> render_click()

      assert [_, thumb_url] =
               Regex.run(~r/<button class="my-images__card".*?<img src="([^"]+)"/s, html)

      assert thumb_url =~ "/media/"

      # And the URL in the markup must resolve to real bytes.
      response = get(conn, thumb_url)

      assert response.status == 200
      assert byte_size(response.resp_body) > 0
    end
  end

  describe "library sort" do
    test "sort select is wrapped in a form so the browser sends phx-change", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")

      # LiveView's client throws "form events require the input to be inside
      # a form" for phx-change on an input outside a <form>, so the sort never
      # reached the server. Guard the structure that makes it work.
      assert html =~ ~r/<form[^>]*phx-change="set_sort"[\s\S]*?id="sort-select"/
    end

    defp card_names(lv) do
      html = render(lv)

      Regex.scan(~r/<span class="card__name">([^<]+)<\/span>/, html)
      |> Enum.map(&hd(tl(&1)))
    end

    test "size sort and the direction toggle reorder the visible list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/")

      big = Path.join(File.cwd!(), "test/fixtures/library/arrow.jpg")
      small = Path.join(File.cwd!(), "test/fixtures/library/swatch.png")

      big_upload =
        file_input(lv, "#upload-form", :images, [
          %{name: "big.jpg", content: File.read!(big), type: "image/jpeg"}
        ])

      small_upload =
        file_input(lv, "#upload-form", :images, [
          %{name: "small.png", content: File.read!(small), type: "image/png"}
        ])

      render_upload(big_upload, "big.jpg")
      render_upload(small_upload, "small.png")
      render_async(lv)

      # Default: name, ascending.
      assert card_names(lv) == ["big.jpg", "small.png"]

      # Size uses the current direction (asc): small file first.
      element(lv, "form.sortrow") |> render_change(%{"sort" => "size"})
      assert card_names(lv) == ["small.png", "big.jpg"]

      # Direction toggle reverses it: desc puts big.jpg first.
      element(lv, ~s(button[phx-click="toggle_direction"])) |> render_click()
      assert card_names(lv) == ["big.jpg", "small.png"]

      # Another toggle flips back to asc.
      element(lv, ~s(button[phx-click="toggle_direction"])) |> render_click()
      assert card_names(lv) == ["small.png", "big.jpg"]

      # Switching to name uses the current (asc) direction: name asc.
      element(lv, "form.sortrow") |> render_change(%{"sort" => "name"})
      assert card_names(lv) == ["big.jpg", "small.png"]
    end
  end

  describe "invert colour toggle" do
    defp upload_image(lv, src) do
      upload =
        file_input(lv, "#upload-form", :images, [
          %{name: "arrow.jpg", content: File.read!(src), type: "image/jpeg"}
        ])

      render_upload(upload, "arrow.jpg")
      render_async(lv)
    end

    defp stage_src(lv) do
      case Regex.run(
             ~r/<img[^>]*?\sid="stage-image"[^>]*?\ssrc="([^"]+)"/,
             render_async(lv)
           ) do
        [_, src] -> src
        _ -> nil
      end
    end

    # A media token signs a payload that embeds a per-call timestamp, so two
    # tokens for the same file never compare equal as strings. To assert that
    # the stage points at a given file, decode the path the token signs.
    defp media_path(nil), do: nil

    defp media_path(url) do
      [_prefix, payload, _signature] = String.split(String.trim_leading(url, "/media/"), ".")

      payload
      |> Base.url_decode64!(padding: false)
      |> :erlang.binary_to_term()
      |> elem(0)
      |> Map.get("p")
    end

    # The preview is generated in a background task; poll until a fresh
    # previews/p_*.png lands in the session (bounded). `render_async` is what
    # lets the LiveView process handle the background task's result message.
    defp wait_for_preview(lv, session, since_mtime, attempts \\ 50) do
      newest =
        session.previews
        |> Path.join("p_*.png")
        |> Path.wildcard()
        |> Enum.max_by(&File.stat!(&1, time: :posix).mtime, fn -> 0 end)

      cond do
        attempts == 0 ->
          flunk("stage preview never updated to a generated previews file")

        newest && newest != 0 && newer_mtime?(newest, since_mtime) ->
          {:ok, newest}

        true ->
          render_async(lv)
          Process.sleep(5)
          wait_for_preview(lv, session, since_mtime, attempts - 1)
      end
    end

    defp newer_mtime?(path, since) do
      File.stat!(path, time: :posix).mtime > since
    end

    defp mean(path) do
      {out, 0} = System.cmd("identify", ["-format", "%[fx:mean]", path], stderr_to_stdout: false)
      {mean, _} = Float.parse(out)
      mean
    end

    test "toggle flips the switch, inverts the on-disk preview and reverts on toggle-off", %{
      conn: conn,
      session: session,
      src: src
    } do
      {:ok, lv, _html} = live(conn, "/")
      upload_image(lv, src)

      render_async(lv)
      html = render(lv)

      refute html =~ "switch--on"
      refute html =~ "Invert colours"
      refute html =~ ~s(aria-checked="true")

      # The original mean (~0.31) is the pre-invert baseline.
      baseline = mean(src)

      # Snapshot the newest preview mtime so we can wait for the freshly
      # generated (inverted) file to land.
      since_mtime =
        session.previews
        |> Path.join("p_*.png")
        |> Path.wildcard()
        |> Enum.max_by(&File.stat!(&1, time: :posix).mtime, fn -> 0 end)
        |> case do
          path when is_binary(path) -> File.stat!(path, time: :posix).mtime
          _ -> 0
        end

      element(lv, "button.switch__control") |> render_click()
      render_async(lv)

      html = render(lv)
      assert html =~ "switch--on"
      assert html =~ "Invert colours"
      # The accessible state tracks operations.invert, not just the CSS class.
      assert html =~ ~s(aria-checked="true")
      assert html =~ "unsaved"

      # Wait for the background preview to regenerate, then prove the pixels
      # are actually the photographic negative (mean -> ~1 - baseline).
      {:ok, preview} = wait_for_preview(lv, session, since_mtime)
      assert abs(mean(preview) - (1 - baseline)) < 0.07

      # Toggling off reverts: switch off, pipeline cleared, stage uses the
      # original library file again.
      original_path = Path.expand(Path.join(session.uploads, "arrow.jpg"))

      element(lv, "button.switch__control") |> render_click()
      render_async(lv)

      html = render(lv)
      refute html =~ "switch--on"
      refute html =~ "Invert colours"
      refute html =~ ~s(aria-checked="true")

      assert media_path(stage_src(lv)) == original_path
    end

    test "applying with invert enabled writes inverted output files", %{
      conn: conn,
      session: session,
      src: src
    } do
      {:ok, lv, _html} = live(conn, "/")
      upload_image(lv, src)

      element(lv, "button.switch__control") |> render_click()
      render_async(lv)

      element(lv, ~s(button[phx-click="apply_changes"])) |> render_click()
      html = render_async(lv)

      assert html =~ "applied"

      files =
        Path.wildcard(Path.join(session.outputs, "*"))
        |> Enum.reject(&File.dir?/1)

      refute files == []
      assert Enum.all?(files, &(mean(&1) > 0.6))
    end
  end

  # The toggle's ON/OFF look is defined purely in CSS; esbuild only bundles
  # JS, so priv/static/assets/app.css (the served stylesheet) is the source of
  # truth — same approach as the badge and settings-layout tests below.
  describe "invert toggle switch styling" do
    test "OFF is a muted grey track, ON is the accent violet, and both animate" do
      css = File.read!(Path.join(File.cwd!(), "priv/static/assets/app.css"))

      # Anchored at line starts so the standalone (OFF) rules are captured,
      # not the `.switch--on ...` variants that merely end in the same name.
      assert [off] = Regex.run(~r/(?:\A|\n)\.switch__control\s*\{[^}]*\}/s, css),
             "expected a .switch__control rule in priv/static/assets/app.css"

      assert [on] = Regex.run(~r/\.switch--on \.switch__control\s*\{[^}]*\}/s, css),
             "expected a .switch--on .switch__control rule"

      assert [thumb_off] = Regex.run(~r/(?:\A|\n)\.switch__thumb\s*\{[^}]*\}/s, css),
             "expected a .switch__thumb rule"

      assert [thumb_on] = Regex.run(~r/\.switch--on \.switch__thumb\s*\{[^}]*\}/s, css),
             "expected a .switch--on .switch__thumb rule"

      # OFF: opaque muted grey, with the UA button border removed, so nothing
      # blends into the panel background or mimics the ON colour.
      assert off =~ ~r/background:\s*#4a506b/
      assert off =~ ~r/border:\s*0/
      refute off =~ "rgba(120, 128, 190, 0.22)"

      # ON: the app's accent violet as a solid fill. A gradient is a
      # background-image and cannot interpolate, which made the old state
      # change jump instead of transitioning.
      assert on =~ ~r/background:\s*var\(--accent\)/
      refute on =~ "linear-gradient"
      refute on =~ "#6c5ce7"

      # Track and knob both animate smoothly between the two states.
      assert off =~ ~r/transition:[^;}]*background-color/
      assert thumb_off =~ ~r/transition:[^;}]*transform/

      # The knob moves right and changes colour when ON, so position and
      # colour each communicate the state on their own.
      assert thumb_on =~ ~r/transform:\s*translateX\(18px\)/
      refute thumb_off =~ "translateX"
      assert thumb_off =~ ~r/background:\s*#bfc6dd/
      assert thumb_on =~ ~r/background:\s*#ffffff/
    end
  end

  describe "sidebar notification badge" do
    test "unseen-saved badge uses a solid, high-contrast notification style in the served CSS" do
      css = File.read!(Path.join(File.cwd!(), "priv/static/assets/app.css"))

      rule =
        Regex.run(~r/\.rail__badge\s*\{[^}]*\}/s, css)
        |> List.first()

      refute is_nil(rule), "expected a .rail__badge rule in priv/static/assets/app.css"

      # Solid notification red on bold white text, sized as a standard pill.
      assert rule =~ ~r/background:\s*#e5484d/
      assert rule =~ ~r/color:\s*#ffffff/
      assert rule =~ ~r/font-weight:\s*700/
      assert rule =~ ~r/border-radius:\s*999px/
      assert rule =~ ~r/height:\s*20px/

      # The old translucent purple treatment is what made the count hard to see.
      refute rule =~ "rgba(124, 108, 255, 0.18)"
      refute rule =~ "#b6adff"
    end
  end

  describe "settings layout" do
    test "the settings panel spans the full main region in the served CSS" do
      css = File.read!(Path.join(File.cwd!(), "priv/static/assets/app.css"))

      rule =
        Regex.run(~r/\.settings\s*\{[^}]*\}/s, css)
        |> List.first()

      refute is_nil(rule), "expected a .settings rule in priv/static/assets/app.css"

      # Full width of the main content region (beside the rail), like My Images.
      assert rule =~ ~r/grid-column:\s*2 \/ -1/
      assert rule =~ "display: grid"

      # The narrow fixed-width card is what left the page looking cramped.
      refute rule =~ "max-width"

      # My Images keeps the same full-width treatment.
      assert css =~ ~r/\.panel\.my-images\s*\{\s*grid-column:\s*2 \/ -1/
    end

    # The CSS can only stretch the panel if this exact markup exists, so pin
    # the container and its two grid children (form column, backend card).
    test "navigating to Settings renders the full-width panel markup", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/")

      lv
      |> element(~s(button.rail__item[phx-value-view="settings"]))
      |> render_click()

      html = render(lv)

      assert html =~ ~s(<section class="panel settings">)
      assert html =~ ~s(<header class="panel__head">)
      assert html =~ ~s(class="settings__form")
      assert html =~ ~s(id="settings-output-dir")
      assert html =~ ~s(class="card-panel")
      assert html =~ "Save Settings"
    end
  end
end
