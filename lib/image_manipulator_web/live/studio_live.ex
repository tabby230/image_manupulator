defmodule ImageManipulatorWeb.StudioLive do
  @moduledoc """
  Full-screen image studio LiveView.

  Three columns:

    * Library — folder picker, uploads and searchable/sortable image list
    * Stage — large preview with zoom, compare, filmstrip, metadata and result
    * Operations — rotate / invert / convert-format pipeline + apply

  Every event handler below is also the name used by `StudioSections`
  templates (e.g. `phx-click="rotate"`), so renames must stay in sync.

  Handled events:
  `nav`, `select_folder`, `refresh_library`, `select_image`, `step_image`,
  `set_layout`, `search`, `clear_search`, `set_sort`, `toggle_direction`,
  `validate_upload`, `cancel_upload`, `folder_browsed`, `delete_upload`,
  `rotate`, `set_rotation`, `toggle_invert`, `set_format`, `set_compression`,
  `reset_operations`, `apply_changes`, `zoom`, `dismiss_error`,
  `save_output`, `remove_output`, `save_settings`, `reset_settings`.
  """

  use ImageManipulatorWeb, :live_view

  import ImageManipulatorWeb.StudioSections

  require Logger

  alias ImageManipulator.{
    Fmt,
    Gallery,
    ImageLibrary,
    ImageProcessor,
    Operations,
    Paths,
    Settings,
    Workspace
  }

  @upload_accept ~w(.jpg .jpeg .png .gif .webp .bmp .tif .tiff .avif)

  @impl true
  def mount(_params, session, socket) do
    Workspace.prune_stale()
    Workspace.prune_thumbs()

    sid = session["studio_sid"]
    workspace = if is_binary(sid), do: Workspace.session(sid), else: Workspace.new_session()
    workspace = Workspace.ensure(workspace)
    settings = Settings.load()
    settings_form = to_form(Settings.to_map(settings), as: :settings)

    folders = with_counts(ImageLibrary.folders(workspace))
    active_folder = List.first(folders)
    folder_images = arranged(images_for(active_folder), :name, :asc, "")
    visible_images = folder_images
    image = List.first(folder_images)

    {:ok,
     socket
     |> assign(
       view: :home,
       session: workspace,
       settings: settings,
       settings_form: settings_form,
       settings_persisted?: Settings.persisted?(),
       settings_error: nil,
       folders: folders,
       active_folder: active_folder,
       folder_images: folder_images,
       visible_images: visible_images,
       image: image,
       query: "",
       view_layout: :grid,
       sort: :name,
       direction: :asc,
       sort_orders: ImageLibrary.sort_orders(),
       operations: Operations.new(),
       metadata: nil,
       metadata_error: nil,
       preview: nil,
       original_url: nil,
       error: nil,
       current_output: nil,
       outputs: [],
       save_error: nil,
       saved: nil,
       save_form: %{file_name: "", location: settings.output_dir},
       applied?: false,
       zoom: 1.0,
       zoom_mode: :fit,
       loaded_image_id: nil,
       recent: ImageLibrary.recent(6),
       processing: nil,
       upload_error: nil,
       env: ImageProcessor.environment(),
       library_stats: ImageLibrary.stats(),
       session_files: 0,
       session_bytes: "0 B",
       thumb_width: settings.thumbnail_size,
       output_dir: settings.output_dir,
       overwrite: settings.overwrite,
       max_upload_size: upload_limit(),
       active_crumb: "Home",
       page_title: "ImageManipulator · Home",
       saved_images: [],
       unseen_saved_count: 0,
       lightbox_image_id: nil
     )
     |> allow_upload(:images,
       accept: @upload_accept,
       max_entries: 200,
       max_file_size: upload_limit(),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> load_selected()
     |> refresh_session_usage()
     |> refresh_saved_images()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="studio" data-view={@view}>
      <.flash_group flash={@flash} />
      <.app_header {assigns} />
      <div class="studio__body">
        <.sidebar {assigns} />
        <%= if @view == :editor or @view == :home do %>
          <.library_panel {assigns} />
          <div class="centre">
            <.stage {assigns} />
          </div>
          <div class="ops-column">
            <.operations_panel {assigns} />
            <.save_panel {assigns} />
          </div>
        <% end %>
        <%= if @view == :my_images do %>
          <.my_images_view {assigns} />
        <% end %>
        <%= if @view == :settings do %>
          <.settings_panel {assigns} />
        <% end %>
      </div>
    </div>
    """
  end

  defp handle_progress(:images, entry, socket) do
    socket =
      if entry.done? do
        case consume_uploaded_entry(socket, entry, fn %{path: path} ->
               if supported_image_entry?(entry) do
                 {:ok,
                  Workspace.store_upload(socket.assigns.session, Map.put(entry, :path, path))}
               else
                 {:ok, :skipped}
               end
             end) do
          {:ok, info} ->
            show_stored_upload(socket, info)

          {:error, reason} ->
            Logger.error("Upload of #{entry.client_name} failed: #{inspect(reason)}")
            assign(socket, upload_error: reason)

          :skipped ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  defp show_stored_upload(socket, _info) do
    session = socket.assigns.session
    folder = ImageLibrary.uploads_folder(session)
    images = arranged(ImageLibrary.list_images(folder.path), :name, :asc, "")

    socket
    |> refresh_folders()
    |> assign(
      active_folder: folder,
      folder_images: images,
      visible_images: images,
      image: List.first(images),
      query: ""
    )
    |> refresh_session_usage()
    |> load_selected()
  end

  # ---------------------------------------------------------------------------
  # Navigation
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("nav", %{"view" => view}, socket) do
    case view do
      "home" ->
        {:noreply,
         assign(socket, view: :home, active_crumb: "Home", page_title: "ImageManipulator · Home")}

      "settings" ->
        {:noreply,
         assign(socket,
           view: :settings,
           active_crumb: "Settings",
           page_title: "ImageManipulator · Settings"
         )}

      "my_images" ->
        {:noreply,
         socket
         |> assign(
           view: :my_images,
           active_crumb: "My Images",
           page_title: "ImageManipulator · My Images"
         )
         |> refresh_saved_images()}

      _editor ->
        {:noreply,
         assign(socket,
           view: :editor,
           active_crumb: "Studio",
           page_title: "ImageManipulator Studio"
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Library: folders, selection, search, sort
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_folder", %{"id" => id}, socket) do
    case ImageLibrary.find_folder(socket.assigns.folders, id) do
      {:ok, folder} ->
        images = arranged(ImageLibrary.list_images(folder.path), socket)

        {:noreply,
         socket
         |> assign(
           active_folder: folder,
           folder_images: images,
           visible_images: images,
           image: List.first(images)
         )
         |> load_selected()}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  @impl true
  def handle_event("refresh_library", _params, socket) do
    socket = socket |> refresh_folders() |> refresh_stats()
    folder = refresh_active_folder(socket.assigns.active_folder, socket.assigns.folders)
    images = if folder, do: arranged(ImageLibrary.list_images(folder.path), socket), else: []
    image = pick_existing(socket.assigns.image, images)

    {:noreply,
     socket
     |> assign(active_folder: folder, folder_images: images, visible_images: images, image: image)
     |> load_selected()}
  end

  @impl true
  def handle_event("select_image", %{"id" => id}, socket) do
    case ImageLibrary.find_image(socket.assigns.folder_images, id) do
      {:ok, image} ->
        {:noreply,
         socket |> assign(view: :editor, image: image, active_crumb: "Studio") |> load_selected()}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  @impl true
  def handle_event("step_image", %{"param" => value}, socket) do
    case step(socket.assigns.folder_images, socket.assigns.image, value) do
      nil -> {:noreply, socket}
      image -> {:noreply, socket |> assign(image: image) |> load_selected()}
    end
  end

  @impl true
  def handle_event("set_layout", %{"layout" => layout}, socket) when layout in ["grid", "list"] do
    {:noreply, assign(socket, view_layout: String.to_existing_atom(layout))}
  end

  def handle_event("set_layout", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     assign(socket,
       query: query,
       visible_images:
         arranged(
           socket.assigns.folder_images,
           socket.assigns.sort,
           socket.assigns.direction,
           query
         )
     )}
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, query: "", visible_images: socket.assigns.folder_images)}
  end

  @impl true
  def handle_event("set_sort", %{"sort" => sort}, socket) do
    case parse_sort(sort) do
      {:ok, order} ->
        socket = assign(socket, sort: order)
        {:noreply, assign(socket, visible_images: arranged(socket.assigns.folder_images, socket))}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_direction", _params, socket) do
    direction = if socket.assigns.direction == :asc, do: :desc, else: :asc
    socket = assign(socket, direction: direction)
    {:noreply, assign(socket, visible_images: arranged(socket.assigns.folder_images, socket))}
  end

  # ---------------------------------------------------------------------------
  # Uploads
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, upload_error: nil)}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  @impl true
  def handle_event("folder_browsed", %{"added" => added, "skipped" => skipped}, socket) do
    added = to_upload_count(added)
    skipped = to_upload_count(skipped)

    socket =
      cond do
        added > 0 and skipped > 0 ->
          socket

        added == 0 and skipped > 0 ->
          socket

        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_upload", %{"id" => id}, socket) do
    case ImageLibrary.find_image(socket.assigns.folder_images, id) do
      {:ok, image} ->
        case Workspace.remove(image.path) do
          :ok ->
            # Remove from folder_images and visible_images
            folder_images = Enum.reject(socket.assigns.folder_images, &(&1.id == id))
            visible_images = Enum.reject(socket.assigns.visible_images, &(&1.id == id))

            # If deleted image was selected, select the next available
            new_image =
              if socket.assigns.image && socket.assigns.image.id == id do
                # Try to select the next image, or previous, or nil if empty
                case step(folder_images, socket.assigns.image, 1) do
                  nil ->
                    # No images left, but check if there's a previous one
                    if folder_images != [] do
                      List.first(folder_images)
                    else
                      nil
                    end

                  next_image ->
                    next_image
                end
              else
                socket.assigns.image
              end

            {:noreply,
             socket
             |> assign(
               folder_images: folder_images,
               visible_images: visible_images,
               image: new_image
             )
              |> load_selected()
              |> refresh_session_usage()}

           {:error, reason} ->
             {:noreply, put_error(socket, reason)}
        end

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  @impl true
  def handle_event("delete_image", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.saved_images, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      entry ->
        case Workspace.remove(entry.path) do
          :ok ->
            saved_images = Enum.reject(socket.assigns.saved_images, &(&1.id == id))
            {:noreply,
             socket
             |> assign(saved_images: saved_images)
             |> put_flash(:info, "Image removed.")}

          {:error, reason} ->
            {:noreply, put_error(socket, reason)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Image operations
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("rotate", %{"param" => value}, socket) do
    case Integer.parse(value || "") do
      {degrees, ""} ->
        operations = Operations.rotate(socket.assigns.operations, degrees)
        {:noreply, socket |> assign(operations: operations) |> refresh_preview()}

      _other ->
        {:noreply, put_error(socket, "Unsupported rotation: #{value}°")}
    end
  end

  @impl true
  def handle_event("set_rotation", %{"param" => value}, socket) do
    with {degrees, ""} <- Integer.parse(value || ""),
         {:ok, operations} <- Operations.set_rotation(socket.assigns.operations, degrees) do
      {:noreply, socket |> assign(operations: operations) |> refresh_preview()}
    else
      {:error, reason} -> {:noreply, put_error(socket, reason)}
      _other -> {:noreply, put_error(socket, "Unsupported rotation: #{value}°")}
    end
  end

  @impl true
  def handle_event("toggle_invert", _params, socket) do
    operations = Operations.toggle_invert(socket.assigns.operations)
    {:noreply, socket |> assign(operations: operations) |> refresh_preview()}
  end

  @impl true
  def handle_event("set_format", %{"param" => value}, socket) do
    with {:ok, format} <- parse_format(value),
         {:ok, operations} <- Operations.set_format(socket.assigns.operations, format) do
      {:noreply,
       socket |> assign(operations: operations) |> refresh_save_name() |> refresh_preview()}
    else
      {:error, reason} -> {:noreply, put_error(socket, reason)}
      :error -> {:noreply, put_error(socket, "Unsupported output format: #{value}.")}
    end
  end

  @impl true
  def handle_event("set_compression", %{"param" => value}, socket) do
    with {:ok, level} <- parse_compression(value),
         {:ok, operations} <- Operations.set_compression(socket.assigns.operations, level) do
      {:noreply, socket |> assign(operations: operations) |> refresh_preview()}
    else
      {:error, reason} -> {:noreply, put_error(socket, reason)}
      :error -> {:noreply, put_error(socket, "Unsupported compression level: #{value}.")}
    end
  end

  @impl true
  def handle_event("reset_operations", _params, socket) do
    if Operations.pending?(socket.assigns.operations) do
      {:noreply,
       socket
       |> assign(operations: Operations.new())
       |> refresh_save_name()
       |> refresh_preview()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply_changes", _params, socket) do
    %{image: image, operations: operations, session: session} = socket.assigns

    cond do
      is_nil(image) ->
        {:noreply, put_error(socket, "Select an image before applying changes.")}

      not Operations.pending?(operations) ->
        {:noreply,
         put_error(socket, "Nothing queued — set a rotation, invert or choose an output format.")}

      true ->
        socket = assign(socket, processing: :apply, error: nil, save_error: nil)

        case Gallery.build(image.path, socket.assigns.metadata, operations,
               target_dir: session.outputs
             ) do
          {:ok, entries} ->
            {:noreply, finish_apply(socket, entries)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(processing: nil, error: reason)}
        end
    end
  end

  @impl true
  def handle_event("preview_output", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.outputs, &(&1.id == id)) do
      nil ->
        {:noreply, put_error(socket, "That output is no longer available.")}

      entry ->
        {:noreply,
         assign(socket,
           current_output: entry,
           preview: %{url: entry.url, processed?: entry.kind != :original, path: entry.path}
         )}
    end
  end

  @impl true
  def handle_event("remove_output", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.outputs, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %{kind: :original} ->
        {:noreply,
         put_error(socket, "The original is a library file and cannot be deleted here.")}

      entry ->
        case Workspace.remove(entry.path) do
          :ok ->
            outputs = Enum.reject(socket.assigns.outputs, &(&1.id == id))
            current = select_current(socket, outputs)

            {:noreply,
             socket
             |> assign(outputs: outputs, current_output: current)
              |> sync_preview()
              |> refresh_session_usage()}

           {:error, reason} ->
             {:noreply, put_error(socket, reason)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Stage controls
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("zoom", %{"param" => value}, socket) do
    zoom = socket.assigns.zoom

    case value do
      "in" ->
        {:noreply, assign(socket, zoom: min(Float.round(zoom * 1.25, 2), 3.0), zoom_mode: :fit)}

      "out" ->
        {:noreply, assign(socket, zoom: max(Float.round(zoom / 1.25, 2), 0.25), zoom_mode: :fit)}

      "fit" ->
        {:noreply, assign(socket, zoom: 1.0, zoom_mode: :fit)}

      "actual" ->
        {:noreply, assign(socket, zoom: 1.0, zoom_mode: :actual)}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, error: nil, save_error: nil)}
  end

  # ---------------------------------------------------------------------------
  # Save As
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("update_save_form", params, socket) do
    save_form = merge_save_form(socket.assigns.save_form, params)
    {:noreply, assign(socket, save_form: save_form, save_error: nil)}
  end

  @impl true
  def handle_event("save_output", params, socket) do
    # The submitted params are the live state of the inputs at the moment
    # "Save Image" was clicked. Merge them into `save_form` before resolving
    # the destination so the written file is driven by the live value of the
    # Save Location field - never a stale cached reference - and so the panel
    # always reflects the value that was used.
    save_form = merge_save_form(socket.assigns.save_form, params)
    file_name = String.trim(save_form.file_name || "")
    location = String.trim(save_form.location || "")
    source = save_source(socket)

    cond do
      is_nil(source) ->
        {:noreply,
         socket
         |> assign(
           save_form: save_form,
           save_error: "Apply your changes (or preview an output) before saving."
         )}

      file_name == "" ->
        {:noreply,
         socket
         |> assign(
           save_form: save_form,
           save_error: "Enter a file name, for example mountain_edited.jpg."
         )}

      true ->
        case resolve_destination(location, file_name, socket.assigns.settings) do
          {:ok, destination} ->
            write_output(socket, source, destination)

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(save_form: save_form, save_error: reason)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_settings", params, socket) do
    case Settings.save_params(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign_settings(settings, true)
         |> put_flash(:info, "✓ Settings saved — output directory is #{settings.output_dir}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(settings_error: reason)}
    end
  end

  @impl true
  def handle_event("reset_settings", _params, socket) do
    settings = Settings.reset()

    {:noreply,
     socket
     |> assign_settings(settings, false)}
  end

  # ---------------------------------------------------------------------------
  # Live preview generation
  # ---------------------------------------------------------------------------

  # Queued operations changed: regenerate the stage preview immediately so the
  # toggle / rotation / compression change is visible on the stage without
  # waiting for "Apply Changes". ImageMagick runs in a background task (see
  # handle_async/3 below) so the existing :preview processing state disables
  # the controls and shows the veil while it renders. When nothing is queued,
  # the original is shown again instead.
  defp refresh_preview(socket) do
    socket =
      socket
      |> assign(processing: :preview, error: nil, applied?: false, current_output: nil)

    case socket.assigns.image do
      nil ->
        assign(socket, processing: nil)

      %{path: path} ->
        if Operations.pending?(socket.assigns.operations) do
          operations = socket.assigns.operations
          preview_dir = socket.assigns.session.previews

          start_async(socket, :preview, fn ->
            generate_preview(path, operations, preview_dir)
          end)
        else
          socket |> cancel_async(:preview) |> invalidate_outputs() |> assign(processing: nil)
        end
    end
  end

  # Runs ImageMagick for the live preview into a fresh session file and mints a
  # cache-busted media URL (unique filename + "?v=" query) so the browser is
  # forced to fetch the new bytes instead of reusing a cached one.
  defp generate_preview(path, operations, preview_dir) do
    File.mkdir_p!(preview_dir)

    preview_path =
      Path.join(preview_dir, "p_" <> to_string(System.unique_integer([:positive])) <> ".png")

    case ImageProcessor.process(path, operations, target: preview_path, overwrite: true) do
      {:ok, _result} ->
        url = Workspace.media_url(preview_path)

        {:ok,
         %{url: url <> "?v=" <> to_string(System.unique_integer([:positive])), path: preview_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only a result sent while the live preview is actually in flight may touch
  # the stage. A task that finishes after the pipeline was reset, re-applied or
  # the selection changed describes a stale operation set, so its outcome is
  # discarded instead of clobbering the current preview / applied state — this
  # keeps the toggle's visual state in sync with what the stage actually shows.
  @impl true
  def handle_async(:preview, {:ok, {:ok, preview}}, %{assigns: %{processing: :preview}} = socket) do
    Workspace.prune_previews(socket.assigns.session)

    {:noreply,
     assign(socket,
       preview: %{url: preview.url, processed?: true, path: preview.path},
       applied?: false,
       current_output: nil,
       processing: nil,
       error: nil
     )}
  end

  def handle_async(:preview, {:ok, {:ok, preview}}, socket) do
    Workspace.remove(preview.path)
    {:noreply, socket}
  end

  def handle_async(
        :preview,
        {:ok, {:error, reason}},
        %{assigns: %{processing: :preview}} = socket
      ) do
    {:noreply, socket |> assign(processing: nil) |> put_error("Preview: #{reason}")}
  end

  def handle_async(:preview, {:ok, {:error, _reason}}, socket), do: {:noreply, socket}

  def handle_async(:preview, {:exit, reason}, %{assigns: %{processing: :preview}} = socket) do
    {:noreply,
     socket
     |> assign(processing: nil)
     |> put_error("Preview task failed: #{inspect(reason)}")}
  end

  def handle_async(:preview, {:exit, _reason}, socket), do: {:noreply, socket}

  # Selection and preview state
  # ---------------------------------------------------------------------------

  # Loads metadata and preview for the selected image, and resets the output
  # gallery when the selection actually changes.
  defp load_selected(socket) do
    image = socket.assigns.image
    same_image? = image && socket.assigns.loaded_image_id == image.id

    socket =
      if same_image? do
        socket
      else
        prune_outputs(socket)
        assign(socket, outputs: [], current_output: nil, applied?: false, saved: nil)
      end

    load_preview(socket, image)
  end

  defp load_preview(socket, nil) do
    assign(socket,
      metadata: nil,
      metadata_error: nil,
      preview: nil,
      original_url: nil,
      current_output: nil,
      applied?: false,
      error: nil,
      save_error: nil,
      saved: nil,
      processing: nil,
      loaded_image_id: nil,
      zoom: 1.0,
      zoom_mode: :fit,
      save_form: default_save_form(nil, socket.assigns.settings, socket.assigns.operations)
    )
  end

  defp load_preview(socket, image) do
    {metadata, metadata_error} =
      case ImageLibrary.metadata(image.path) do
        {:ok, info} -> {info, nil}
        {:error, reason} -> {nil, reason}
      end

    original_url = Workspace.media_url(image.path)

    preview =
      if metadata do
        %{url: original_url, processed?: false, path: image.path}
      else
        nil
      end

    operations =
      if socket.assigns.loaded_image_id == image.id do
        socket.assigns.operations
      else
        Operations.new()
      end

    assign(socket,
      metadata: metadata,
      metadata_error: metadata_error,
      original_url: original_url,
      preview: preview,
      operations: operations,
      current_output: nil,
      applied?: false,
      error: nil,
      save_error: nil,
      saved: nil,
      processing: nil,
      loaded_image_id: image.id,
      zoom: 1.0,
      zoom_mode: :fit,
      save_form: default_save_form(image, socket.assigns.settings, operations)
    )
  end

  # Queued operations changed: the previous files no longer describe the
  # pipeline, so drop the pointer and show the original again.
  defp invalidate_outputs(socket) do
    preview =
      case {socket.assigns.image, socket.assigns.original_url} do
        {%{path: path}, url} when is_binary(url) -> %{url: url, processed?: false, path: path}
        _other -> socket.assigns.preview
      end

    assign(socket, applied?: false, current_output: nil, preview: preview, error: nil)
  end

  defp sync_preview(socket) do
    case socket.assigns.current_output do
      %{url: url, path: path, kind: kind} ->
        assign(socket, preview: %{url: url, processed?: kind != :original, path: path})

      _other ->
        invalidate_outputs(socket)
    end
  end

  defp finish_apply(socket, entries) do
    prune_outputs(socket)
    decorated = decorate(entries, socket.assigns.thumb_width)
    current = Enum.find(decorated, & &1.applied?) || List.first(decorated)

    socket
    |> assign(
      outputs: decorated,
      current_output: current,
      applied?: true,
      processing: nil,
      error: nil,
      save_error: nil,
      saved: nil,
      preview: %{url: current.url, processed?: current.kind != :original, path: current.path}
    )
    |> refresh_session_usage()
  end

  # Deletes the files generated by the previous pipeline run. Originals are
  # library files and are never touched.
  defp prune_outputs(socket) do
    socket.assigns.outputs
    |> Enum.reject(&(&1.kind == :original))
    |> Enum.each(fn entry ->
      case Workspace.remove(entry.path) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end)
  end

  # Signed media URLs for every gallery entry.

  defp decorate(entries, thumb_width) do
    Enum.map(entries, fn entry ->
      %{
        entry
        | url: Workspace.media_url(entry.path),
          thumb_url: Workspace.media_url(entry.path, width: thumb_width),
          download_url: Workspace.media_url(entry.path, download: true)
      }
    end)
  end
  

  # ---------------------------------------------------------------------------
  # Saving
  # ---------------------------------------------------------------------------

  # Merges the live submitted form values over the current save form. Each key
  # that arrived from the browser wins - including an empty string, so a field
  # the user cleared is cleared rather than silently retaining the old value.
  # Keys missing from the submission keep the current value (the browser only
  # sends inputs that are present in the form).
  defp merge_save_form(save_form, params) do
    %{
      file_name:
        if(Map.has_key?(params, "file_name"), do: params["file_name"], else: save_form.file_name),
      location:
        if(Map.has_key?(params, "location"), do: params["location"], else: save_form.location)
    }
  end

  # The file the Save panel writes: the selected output when there is one,
  # otherwise the preview the stage is showing.
  defp save_source(socket) do
    case socket.assigns.current_output do
      %{path: path} = entry ->
        %{path: path, label: entry.label}

      _other ->
        case socket.assigns.preview do
          %{path: path} when is_binary(path) -> %{path: path, label: "Preview"}
          _none -> nil
        end
    end
  end

  defp resolve_destination(location, file_name, settings) do
    name = Workspace.sanitise_filename(file_name)

    dir =
      cond do
        location in [nil, ""] -> settings.output_dir
        Path.type(location) == :absolute -> location
        true -> Path.expand(location, Paths.project_root())
      end

    destination = Path.expand(Path.join(dir, name))

    cond do
      not String.contains?(name, ".") ->
        {:error, "Include a file extension, for example #{name}.jpg."}

      Paths.readable?(destination) and not Paths.writable?(destination) ->
        {:error, "#{dir} is part of the read-only image library. Pick another location."}

      not Settings.writable_directory?(dir) ->
        {:error, "Cannot write to #{dir}. Choose an existing, writable directory."}

      true ->
        {:ok, destination}
    end
  end

  defp write_output(socket, source, destination) do
    quality = Operations.jpg_quality(socket.assigns.operations)

    case Gallery.save_as(source.path, destination,
           quality: quality,
           overwrite: socket.assigns.overwrite
         ) do
      {:ok, saved} ->
        dir = Path.dirname(saved.path)

        settings =
          if socket.assigns.settings.output_dir == dir do
            socket.assigns.settings
          else
            case Settings.save(%{socket.assigns.settings | output_dir: dir}) do
              {:ok, updated} -> updated
              {:error, _reason} -> socket.assigns.settings
            end
          end

        {:noreply,
         socket
         |> assign(
           saved: %{
             name: Path.basename(saved.path),
             dir: dir,
             path: saved.path,
             bytes: saved.bytes
           },
           save_error: nil,
           settings: settings,
           settings_form: to_form(Settings.to_map(settings), as: :settings),
           settings_persisted?: Settings.persisted?(),
           save_form: %{
             file_name: Path.basename(saved.path),
             location: dir
           }
         )
         |> add_saved_image(saved.path)
         |> refresh_session_usage()
         |> put_flash(:info, "✓ Image saved successfully")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(save_error: reason)}
    end
  end

  defp default_save_form(image, settings, operations) do
    location =
      case settings do
        %{output_dir: dir} when is_binary(dir) and dir != "" -> dir
        _other -> Settings.output_dir()
      end

    %{file_name: suggested_name(image, operations), location: location}
  end

  defp suggested_name(nil, _operations), do: ""

  defp suggested_name(%{name: name}, operations) do
    base = Path.basename(name, Path.extname(name))
    "#{base}_edited#{Operations.output_extension(operations) || Path.extname(name)}"
  end

  defp refresh_save_name(socket) do
    form =
      default_save_form(socket.assigns.image, socket.assigns.settings, socket.assigns.operations)

    assign(socket, save_form: %{form | location: socket.assigns.save_form.location})
  end

  # ---------------------------------------------------------------------------
  # Library / settings bookkeeping
  # ---------------------------------------------------------------------------

  defp refresh_folders(socket) do
    assign(socket, folders: with_counts(ImageLibrary.folders(socket.assigns.session)))
  end

  defp refresh_stats(socket) do
    assign(socket, library_stats: ImageLibrary.stats(), recent: ImageLibrary.recent(6))
  end

  defp refresh_session_usage(socket) do
    usage = Workspace.usage(socket.assigns.session)

    assign(socket, session_files: usage.files, session_bytes: Fmt.bytes(usage.bytes))
  end

  defp refresh_saved_images(socket) do
    dir = socket.assigns.settings.output_dir

    saved_images =
      dir
      |> ImageLibrary.list_images()
      |> Enum.map(&Map.put(&1, :id, &1.path))
      |> Enum.sort_by(& &1.mtime, :desc)

    assign(socket, saved_images: saved_images, unseen_saved_count: 0)
  end

  # Appends a freshly written output file to the in-session "My Images"
  # gallery (most recent first) and bumps the unseen badge count.
  defp add_saved_image(socket, path) do
    ext = path |> Path.extname() |> String.trim_leading(".") |> String.upcase()

    {bytes, mtime} =
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{size: size, mtime: mtime}} ->
          {size, DateTime.from_unix!(mtime)}

        {:error, _reason} ->
          {0, DateTime.utc_now()}
      end

    # Only the path is stored: the gallery derives its signed `/media/:token`
    # URLs at render time - the same source logic the Home images list uses - so
    # a thumbnail-size change in Settings shows up on the next render instead of
    # leaving a stale URL behind.
    entry = %{
      id: path,
      path: path,
      name: Path.basename(path),
      bytes: bytes,
      mtime: mtime,
      format_label: if(ext == "", do: "FILE", else: ext)
    }

    saved_images = [entry | Enum.reject(socket.assigns.saved_images, &(&1.id == path))]

    assign(socket,
      saved_images: saved_images,
      unseen_saved_count: socket.assigns.unseen_saved_count + 1
    )
  end

  defp assign_settings(socket, settings, persisted?) do
    socket
    |> assign(
      settings: settings,
      settings_form: to_form(Settings.to_map(settings), as: :settings),
      settings_persisted?: persisted?,
      settings_error: nil,
      thumb_width: settings.thumbnail_size,
      output_dir: settings.output_dir,
      overwrite: settings.overwrite,
      save_form: %{socket.assigns.save_form | location: settings.output_dir}
    )
    |> refresh_saved_images()
  end

  defp with_counts(folders) do
    Enum.map(folders, fn folder ->
      Map.put(folder, :count, ImageLibrary.count_images(folder.path))
    end)
  end

  defp refresh_active_folder(nil, folders), do: List.first(folders)

  defp refresh_active_folder(active, folders) do
    Enum.find(folders, &(&1.id == active.id)) || List.first(folders)
  end

  defp pick_existing(nil, images), do: List.first(images)

  defp pick_existing(image, images) do
    Enum.find(images, &(&1.id == image.id)) || List.first(images)
  end

  # Keeps the stage pointed at something sensible after an output is deleted.
  defp select_current(_socket, []), do: nil

  defp select_current(socket, outputs) do
    current = socket.assigns.current_output

    cond do
      current && Enum.any?(outputs, &(&1.id == current.id)) ->
        Enum.find(outputs, &(&1.id == current.id))

      true ->
        Enum.find(outputs, & &1.applied?) || Enum.find(outputs, &(&1.kind != :original)) ||
          List.first(outputs)
    end
  end

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  defp arranged(images, socket) do
    arranged(images, socket.assigns.sort, socket.assigns.direction, socket.assigns.query)
  end

  defp arranged(images, order, direction, query) do
    images
    |> ImageLibrary.filter_images(query)
    |> ImageLibrary.sort_images(order, direction)
  end

  defp step([], _image, _value), do: nil

  defp step(images, nil, value) do
    if backwards?(value), do: List.last(images), else: List.first(images)
  end

  defp step(images, image, value) do
    index = Enum.find_index(images, &(&1.id == image.id)) || 0
    offset = if backwards?(value), do: -1, else: 1
    Enum.at(images, Integer.mod(index + offset, length(images)))
  end

  defp backwards?(value), do: String.starts_with?(to_string(value), "-")

  defp parse_sort(sort) do
    case Enum.find(ImageLibrary.sort_orders(), &(Atom.to_string(&1) == sort)) do
      nil -> :error
      order -> {:ok, order}
    end
  end

  defp parse_compression(level) do
    case Enum.find(Operations.compression_levels(), &(Atom.to_string(&1) == level)) do
      nil -> :error
      parsed -> {:ok, parsed}
    end
  end

  defp parse_format(value) do
    case Enum.find(Operations.formats(), &(Atom.to_string(&1) == value)) do
      nil -> :error
      format -> {:ok, format}
    end
  end

  defp images_for(nil), do: []
  defp images_for(folder), do: ImageLibrary.list_images(folder.path)

  defp supported_image_entry?(entry) do
    String.starts_with?(entry.client_type || "", "image/") or
      ImageLibrary.image_name?(entry.client_name || "")
  end

  defp to_upload_count(value) when is_integer(value), do: value
  defp to_upload_count(value) when is_float(value), do: round(value)
  defp to_upload_count(value), do: String.to_integer(to_string(value))

  defp upload_limit, do: Application.get_env(:image_manipulator, :max_upload_size, 25_000_000)

  defp put_error(socket, reason) when is_binary(reason), do: assign(socket, error: reason)
end
