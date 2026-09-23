
defmodule ImageManipulatorWeb.StudioSections do
  @moduledoc """
  Page sections for the studio LiveView.

  Each component receives the LiveView's assigns as a whole
  (`<.stage {assigns} />`) because they are page sections rather than reusable
  widgets; the assigns each one reads are listed in its `@doc`.

  The visual language lives in `priv/static/assets/app.css`: glass panels over a
  deep navy to purple gradient, with every colour drawn from a CSS custom
  property so the theme can be retuned from one place.
  """

  use Phoenix.Component

  import ImageManipulatorWeb.StudioComponents

  alias ImageManipulator.{Fmt, Operations, Workspace}
  alias Phoenix.LiveView.JS

  # -------------------------------------------------------------------------
  # Application shell
  # -------------------------------------------------------------------------

  @doc """
  Top bar.

  Reads: `view`, `active_crumb`, `image`, `env`, `library_stats`, `processing`.
  """
  def app_header(assigns) do
    ~H"""
    <header class="appbar">
      <div class="appbar__brand">
        <img src="/assets/logo.png" alt="Logo" class="brand-logo" />
        <span class="brand-text">
          <strong>Transform · Enhance · Save</strong>
          <small>Phoenix LiveView image studio</small>
        </span>
      </div>

      <nav class="appbar__crumbs" aria-label="Breadcrumb">
        <.icon name={:folder} size={14} />
        <span class="crumb">{@active_crumb}</span>
        <span class="crumb-sep">/</span>
        <span class="crumb crumb--strong">
          {if @image, do: @image.name, else: "no selection"}
        </span>
      </nav>

      <div class="appbar__status">
        <span :if={@processing} class="pill pill--busy">
          <.spinner size={12} label={processing_label(@processing)} />
        </span>

        <span class={if @env && @env.available?, do: "pill pill--ok", else: "pill pill--danger"}>
          <.icon name={:cpu} size={13} />
          {if @env, do: @env.version || "backend unavailable", else: "probing backend"}
        </span>

        <span class="pill pill--ghost">
          <.icon name={:layers} size={13} /> {@library_stats.images} images
        </span>
      </div>
    </header>
    """
  end

  @doc """
  Left navigation rail.

  Reads: `view`, `unseen_saved_count`, `settings_persisted?`.
  """
  def sidebar(assigns) do
    ~H"""
    <nav class="rail" aria-label="Sections">
      <button class={"rail__item" <> active_class(@view, :home)} phx-click="nav" phx-value-view="home">
        <.icon name={:home} size={20} />
        <span>Home</span>
      </button>

      <button
        class={"rail__item" <> active_class(@view, :my_images)}
        phx-click="nav"
        phx-value-view="my_images"
      >
        <.icon name={:images} size={20} />
        <span>My Images</span>
        <span :if={@unseen_saved_count > 0} class="rail__badge">{@unseen_saved_count}</span>
      </button>

      <button
        class={"rail__item" <> active_class(@view, :settings)}
        phx-click="nav"
        phx-value-view="settings"
      >
        <.icon name={:settings} size={20} />
        <span>Settings</span>
        <span :if={@settings_persisted?} class="rail__dot" title="Settings saved to disk"></span>
      </button>
    </nav>
    """
  end

  defp active_class(value, value), do: " rail__item--active"
  defp active_class(_value, _expected), do: ""

  defp backend_label(nil), do: "ImageMagick"
  defp backend_label(%{version: nil}), do: "ImageMagick (probing)"
  defp backend_label(%{version: version}), do: version

  defp processing_label(:preview), do: "Processing preview"
  defp processing_label(:apply), do: "Applying changes"
  defp processing_label(:save), do: "Saving file"
  defp processing_label(_other), do: "Working"
  # -------------------------------------------------------------------------
  # Library (folders, uploads, image browsing)
  # -------------------------------------------------------------------------

  @doc """
  Folder picker, uploader, image browser and the output gallery (docked below
  the image list).

  Reads: `folders`, `active_folder`, `folder_images`, `visible_images`,
  `query`, `layout`, `sort`, `sort_orders`, `image`, `uploads`,
  `upload_error`, `thumb_width`, `processing`, `max_upload_size`,
  `outputs`, `current_output`.
  """
  def library_panel(assigns) do
    ~H"""
    <section class="library panel">
      <header class="panel__head">
        <div id="folder-browse" phx-hook="FolderBrowse" data-upload-ref={@uploads.images.ref}>
          <button
            type="button"
            class="btn btn--ghost btn--sm"
            title="Browse a folder from your computer"
          >
            <.icon name={:folder} size={14} /> Browse Folder
          </button>
          <input type="file" webkitdirectory multiple accept="image/*" style="display: none" />
        </div>
      </header>

      <div class="folders">
        <button
          :for={folder <- @folders}
          class={"folder" <> folder_active(@active_folder, folder)}
          phx-click="select_folder"
          phx-value-id={folder.id}
          title={folder.path}
        >
          <span class="folder__icon">
            <.icon name={folder_icon(folder)} size={16} />
          </span>
          <span class="folder__text">
            <span class="folder__name">{folder.label}</span>
            <span class="folder__path">{shorten_path(folder.path, 34)}</span>
          </span>
          <span class="folder__count">{folder.count}</span>
        </button>
      </div>

      <form
        id="upload-form"
        class="uploader"
        phx-change="validate_upload"
        phx-drop-target={@uploads.images.ref}
      >
        <div class="uploader__drop">
          <.icon name={:upload} size={16} />
          <label class="uploader__pick" for={@uploads.images.ref}>Choose images</label>
          <span class="uploader__hint">or drop files · up to {Fmt.bytes(@max_upload_size)} each</span>
          <.live_file_input upload={@uploads.images} class="uploader__input" />
        </div>

        <div :for={entry <- @uploads.images.entries} class="uploader__entry">
          <div class="uploader__row">
            <span class="uploader__name" title={entry.client_name}>{entry.client_name}</span>
            <button
              type="button"
              class="btn btn--icon btn--sm"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              aria-label="Cancel upload"
            >
              <.icon name={:x} size={13} />
            </button>
          </div>
          <div class="bar" title={"#{entry.progress}% uploaded"}>
            <span class="bar__fill" style={"width: #{entry.progress}%"}></span>
          </div>
          <div :for={error <- upload_errors(@uploads.images, entry)} class="uploader__error">
            {upload_error_message(error)}
          </div>
        </div>

        <div :for={error <- upload_errors(@uploads.images)} class="uploader__error">
          {upload_error_message(error)}
        </div>

        <p :if={@upload_error} class="uploader__error">{@upload_error}</p>
      </form>

      <header class="panel__head panel__head--browse">
        <div class="panel__title">
          <.icon name={:images} size={16} />
          <span>Images</span>
          <span class="panel__count">{length(@visible_images)}/{length(@folder_images)}</span>
        </div>
        <div class="toolbar">
          <button
            class={"btn btn--icon btn--sm" <> toggle_class(@view_layout, :grid)}
            phx-click="set_layout"
            phx-value-layout="grid"
            aria-label="Grid view"
          >
            <.icon name={:grid} size={14} />
          </button>
          <button
            class={"btn btn--icon btn--sm" <> toggle_class(@view_layout, :list)}
            phx-click="set_layout"
            phx-value-layout="list"
            aria-label="List view"
          >
            <.icon name={:list} size={14} />
          </button>
        </div>
      </header>

      <form class="searchrow" phx-change="search" phx-submit="search">
        <span class="searchrow__icon"><.icon name={:search} size={14} /></span>
        <input
          type="search"
          name="query"
          value={@query}
          phx-debounce="200"
          placeholder="Search by file name…"
          autocomplete="off"
        />
        <button
          :if={@query != ""}
          type="button"
          class="btn btn--icon btn--sm"
          phx-click="clear_search"
        >
          <.icon name={:x} size={13} />
        </button>
      </form>

    <!-- The phx-change binding only works on inputs that live inside a
           form, so the sort select is wrapped in one. -->
      <form class="sortrow" phx-change="set_sort">
        <label class="sortrow__label" for="sort-select"><.icon name={:sort} size={13} /> Sort</label>
        <select id="sort-select" name="sort">
          <option :for={order <- @sort_orders} value={order} selected={order == @sort}>
            {sort_label(order)}
          </option>
        </select>
        <button
          type="button"
          class="btn btn--ghost btn--sm"
          phx-click="toggle_direction"
          title={"Direction: #{@direction}"}
        >
          {direction_label(@direction)}
        </button>
      </form>

      <.image_list
        images={@visible_images}
        image={@image}
        layout={@view_layout}
        thumb_width={@thumb_width}
        disabled={@processing != nil}
      />

      <.outputs_panel {assigns} />
    </section>
    """
  end

  @doc """
  Grid or list of the images in the open folder; each entry is a real thumbnail
  served by `/media/:token`.

  Reads: `images`, `image`, `layout`, `thumb_width`, `disabled`.

  Note: `layout` is passed by `library_panel` as `layout={@view_layout}` from the
  parent LiveView, which keeps the LiveView's reserved `:layout` assign free.
  """
  def image_list(assigns) do
    ~H"""
    <div :if={@images == []} class="imagelist imagelist--empty">
      <.empty_state
        icon={:image}
        title="No images here"
        body="Pick another folder or store a file in this session's workspace."
      />
    </div>

    <div :if={@images != []} class={"imagelist " <> list_class(@layout)}>
      <div :for={item <- @images} class={"card-wrapper" <> card_active(@image, item)}>
        <button
          class={"card" <> card_active(@image, item)}
          phx-click="select_image"
          phx-value-id={item.id}
          disabled={@disabled}
          title={item.path}
        >
          <span class="card__thumb">
            <img
              src={Workspace.media_url(item.path, width: @thumb_width)}
              alt={item.name}
              loading="lazy"
              decoding="async"
            />
            <span class="card__format">{item.format_label}</span>
            <span
              role="button"
              tabindex="0"
              class="card__delete"
              phx-click="delete_upload"
              phx-value-id={item.id}
              onclick="event.stopPropagation()"
              data-confirm="Delete this image? This cannot be undone."
              aria-label="Delete image"
              title="Delete this image"
            >
              <.icon name={:trash} size={13} />
            </span>
          </span>
          <span class="card__body">
            <span class="card__name">{item.name}</span>
            <span class="card__meta">
              {Fmt.bytes(item.bytes)} · {Fmt.ago(item.mtime)}
            </span>
          </span>
        </button>
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------------
  # Preview stage
  # -------------------------------------------------------------------------

  @doc """
  Centre column: preview, toolbar, metadata, result and filmstrip.

  The viewport doubles as a drop target for the image upload (same ref as
  the sidebar's upload widget), so dropping a file stores and selects it.

  Reads: `image`, `metadata`, `metadata_error`, `preview`, `original_url`,
  `operations`, `applied?`, `current_output`, `zoom`, `processing`, `error`,
  `folder_images`, `thumb_width`, `uploads`.
  """
  def stage(assigns) do
    ~H"""
    <section class="stage panel">
      <header class="stage__head">
        <div class="stage__heading">
          <h2 class="stage__name">{if @image, do: @image.name, else: "No image selected"}</h2>
          <div class="stage__badges">
            <span :if={@image} class="badge badge--muted">{@image.format_label}</span>
            <span :if={@metadata} class="badge badge--muted">
              {Fmt.dimensions(@metadata.width, @metadata.height)}
            </span>
            <span :if={@metadata} class="badge badge--muted">{Fmt.bytes(@metadata.bytes)}</span>
            <span :if={@metadata && @metadata.has_alpha?} class="badge badge--accent">alpha</span>
            <span :if={@preview && @preview.processed?} class="badge badge--warn">
              <.icon name={:sparkles} size={12} /> processed preview
            </span>
            <span :if={@applied?} class="badge badge--ok">
              <.icon name={:check} size={12} /> applied
            </span>
          </div>
        </div>

        <div class="stage__actions">
          <div class="btn-group">
            <button
              class="btn btn--icon"
              phx-click="rotate"
              phx-value-param="-90"
              disabled={!@image}
              title="Rotate left"
            >
              <.icon name={:rotate_ccw} size={16} />
            </button>
            <button
              class="btn btn--icon"
              phx-click="rotate"
              phx-value-param="90"
              disabled={!@image}
              title="Rotate right"
            >
              <.icon name={:rotate_cw} size={16} />
            </button>
          </div>

          <button
            class="btn btn--soft btn--sm"
            type="button"
            data-stage-action="compare"
            data-compare-src={@original_url}
            disabled={!@preview || !@preview.processed?}
            title="Hold to compare with the original"
          >
            <.icon name={:eye} size={14} /> Hold to compare
          </button>

          <div class="btn-group">
            <button
              class="btn btn--icon"
              phx-click="zoom"
              phx-value-param="out"
              disabled={!@image}
              title="Zoom out"
            >
              <.icon name={:zoom_out} size={16} />
            </button>
            <button
              class="btn btn--icon"
              phx-click="zoom"
              phx-value-param="in"
              disabled={!@image}
              title="Zoom in"
            >
              <.icon name={:zoom_in} size={16} />
            </button>
            <button
              class="btn btn--icon"
              phx-click="zoom"
              phx-value-param="fit"
              disabled={!@image}
              title="Fit to view"
            >
              <.icon name={:fit} size={16} />
            </button>
            <button
              class="btn btn--icon"
              phx-click="zoom"
              phx-value-param="actual"
              disabled={!@image}
              title="Actual pixels"
            >
              <span class="btn__text">{zoom_label(@zoom)}</span>
            </button>
          </div>

          <button
            class="btn btn--ghost btn--sm"
            type="button"
            data-stage-action="fullscreen"
            phx-click={JS.dispatch("app:fullscreen", to: "#stage-viewport")}
            disabled={!@image}
            title="Toggle fullscreen"
          >
            <.icon name={:maximize} size={14} /> Fullscreen
          </button>
        </div>
      </header>

      <div
        class="stage__viewport"
        id="stage-viewport"
        phx-hook="Stage"
        data-zoom={@zoom}
        phx-drop-target={@uploads.images.ref}
      >
        <img
          :if={@preview}
          id="stage-image"
          class="stage__img"
          src={@preview.url}
          data-original-src={@original_url}
          style={"--zoom: #{@zoom}"}
          alt="Selected image preview"
        />

        <div :if={!@preview} class="stage__placeholder">
          <.empty_state
            icon={:images}
            title="Select an image to begin"
            body="Pick a folder on the left, then choose an image. Rotation, inversion and format conversion all run on the server."
          />
        </div>

        <div :if={@processing == :preview} class="stage__veil">
          <.spinner size={24} label="Running ImageMagick…" />
        </div>

        <div :if={@error && @image} class="stage__alert">
          <.icon name={:alert} size={15} />
          <span>{@error}</span>
          <button class="btn btn--icon btn--sm" phx-click="dismiss_error" aria-label="Dismiss">
            <.icon name={:x} size={12} />
          </button>
        </div>
      </div>

      <div class="stage__strip">
        <button
          class="btn btn--icon"
          phx-click="step_image"
          phx-value-param="-1"
          disabled={!@image}
          title="Previous image"
        >
          <.icon name={:chevron_left} size={16} />
        </button>

        <div class="filmstrip" id="filmstrip">
          <button
            :for={item <- @folder_images}
            class={"thumb" <> thumb_active(@image, item)}
            phx-click="select_image"
            phx-value-id={item.id}
            title={item.name}
            data-active-thumb={to_string(@image && @image.id == item.id)}
          >
            <img src={Workspace.media_url(item.path, width: 96)} alt={item.name} loading="lazy" />
            <span class="thumb__label">{item.name}</span>
          </button>

          <span :if={@folder_images == []} class="filmstrip__empty">
            No images in this folder yet
          </span>
        </div>

        <button
          class="btn btn--icon"
          phx-click="step_image"
          phx-value-param="1"
          disabled={!@image}
          title="Next image"
        >
          <.icon name={:chevron_right} size={16} />
        </button>
      </div>

      <div class="stage__meta">
        <.source_card metadata={@metadata} metadata_error={@metadata_error} image={@image} />
        <.result_card
          result={@current_output}
          preview={@preview}
          metadata={@metadata}
          operations={@operations}
          applied?={@applied?}
        />
      </div>
    </section>
    """
  end

  # -------------------------------------------------------------------------
  # Metadata + result cards
  # -------------------------------------------------------------------------

  @doc """
  Metadata card for the selected file.

  Reads: `metadata`, `metadata_error`, `image`.
  """
  def source_card(assigns) do
    ~H"""
    <article class="card-panel">
      <header class="card-panel__head">
        <.icon name={:info} size={15} />
        <span>Source metadata</span>
        <span :if={@metadata} class="badge badge--muted">identify</span>
      </header>

      <div :if={@metadata_error} class="alert alert--error">
        <.icon name={:alert} size={14} /> {@metadata_error}
      </div>

      <div :if={@metadata} class="metagrid">
        <.meta_row label="File" value={@metadata.name} />
        <.meta_row label="Format" value={@metadata.format_label} />
        <.meta_row label="Dimensions" value={Fmt.dimensions(@metadata.width, @metadata.height)} />
        <.meta_row label="Megapixels" value={to_string(@metadata.megapixels)} />
        <.meta_row label="File size" value={Fmt.bytes(@metadata.bytes)} />
        <.meta_row label="Colour space" value={@metadata.colorspace} />
        <.meta_row label="Bit depth" value={"#{@metadata.depth}-bit"} />
        <.meta_row label="Channels" value={to_string(@metadata.channels)} />
        <.meta_row label="EXIF orientation" value={@metadata.orientation} />
        <.meta_row label="Transparency" value={alpha_label(@metadata.has_alpha?)} />
        <.meta_row label="Modified" value={Fmt.datetime(@metadata.mtime)} />
        <.meta_row label="Path" value={shorten_path(@metadata.path, 38)} mono />
      </div>

      <div :if={!@metadata && !@metadata_error} class="card-panel__idle">
        Nothing loaded yet — select an image to read its metadata with ImageMagick.
      </div>
    </article>
    """
  end

  @doc """
  Card describing the processed result (applied output or live preview).

  Reads: `result`, `preview`, `metadata`, `operations`, `applied?`.
  """
  def result_card(assigns) do
    ~H"""
    <article class="card-panel card-panel--result">
      <header class="card-panel__head">
        <.icon name={:layers} size={15} />
        <span>Result</span>
        <span :if={@applied? && @result} class="badge badge--ok">applied</span>
        <span :if={@preview && @preview.processed? && !@applied?} class="badge badge--warn">
          preview
        </span>
      </header>

      <div :if={@result} class="metagrid">
        <.meta_row label="Output file" value={Path.basename(@result.path)} />
        <.meta_row label="Format" value={@result.format_label} />
        <.meta_row label="Dimensions" value={Fmt.dimensions(@result.width, @result.height)} />
        <.meta_row label="File size" value={Fmt.bytes(@result.bytes)} />
        <.meta_row :if={@result.quality} label="Quality" value={"#{@result.quality}%"} />
        <.meta_row label="Difference" value={compare_size(@result, @metadata)} />
        <.meta_row label="Processing time" value={"#{@result.elapsed_ms} ms"} />
        <.meta_row label="Written to" value={shorten_path(@result.path, 38)} mono />
      </div>

      <div :if={!@result && @preview && @preview.processed?} class="card-panel__note">
        <p>
          Live preview only — press <strong>Apply Changes</strong> to write it into the workspace.
        </p>
        <ul class="ops-list">
          <li :for={step <- operation_summary(@operations)}>
            <.icon name={:check} size={12} /> {step}
          </li>
        </ul>
      </div>

      <div :if={!@result && !(@preview && @preview.processed?)} class="card-panel__idle">
        No operations queued — the preview is the untouched original.
      </div>

      <div :if={@result && @result.operations != []} class="ops-chips">
        <span :for={step <- @result.operations} class="chip">{step}</span>
      </div>
    </article>
    """
  end

  # -------------------------------------------------------------------------
  # Image operations panel
  # -------------------------------------------------------------------------

  @doc """
  The right-hand "Image Operations" panel.

  Reads: `operations`, `image`, `processing`.
  """
  def operations_panel(assigns) do
    ops = assigns.operations

    assigns =
      assign(assigns,
        rotation: ops.rotation,
        invert: ops.invert,
        target_format: ops.format,
        compressible: Operations.compressible?(ops),
        compression: ops.compression,
        pending: Operations.pending?(ops),
        quality: Operations.jpg_quality(ops)
      )

    ~H"""
    <section class="panel ops">
      <header class="panel__head">
        <div class="panel__title">
          <.icon name={:sliders} size={16} />
          <span>Image Operations</span>
        </div>
        <span :if={@pending} class="badge badge--warn">unsaved</span>
        <span :if={!@pending} class="badge badge--muted">idle</span>
      </header>

      <div class="ops__block">
        <div class="ops__label">
          <.icon name={:rotate_cw} size={14} /> Rotate <span class="ops__value">{@rotation}°</span>
        </div>
        <div class="seg">
          <.segment
            :for={angle <- Operations.rotations()}
            active={@rotation == angle}
            event="set_rotation"
            param={to_string(angle)}
            label={rotation_label(angle)}
            disabled={!@image || @processing != nil}
          />
        </div>
        <div class="ops__hint">90° and 270° swap the width and height of the output.</div>
      </div>

      <div class="ops__block">
        <.switch
          on={@invert}
          event="toggle_invert"
          label="Invert Colours"
          hint="Photographic negative (-negate in ImageMagick)"
          disabled={!@image || @processing != nil}
        />
      </div>

      <div class="ops__block">
        <div class="ops__label">
          <.icon name={:convert} size={14} /> Convert Format
          <span class="ops__value">{Operations.format_label(@operations)}</span>
        </div>
        <div class="seg">
          <.segment
            :for={format <- Operations.formats()}
            active={@target_format == format}
            event="set_format"
            param={to_string(format)}
            label={format |> to_string() |> String.upcase()}
            disabled={!@image || @processing != nil}
          />
        </div>

        <div class={"ops__sub" <> if(@compressible, do: "", else: " ops__sub--dim")}>
          <div class="ops__label">
            <.icon name={:palette} size={14} /> Compression
            <span class="ops__value">quality {@quality}%</span>
          </div>
          <div class="seg">
            <.segment
              :for={level <- Operations.compression_levels()}
              active={@compression == level}
              event="set_compression"
              param={to_string(level)}
              label={Operations.compression_label(level)}
              disabled={!@image || !@compressible || @processing != nil}
            />
          </div>
          <div class="ops__hint">
            <%= if @compressible do %>
              Low keeps the most detail, High produces the smallest file.
            <% else %>
              PNG is lossless — compression does not apply.
            <% end %>
          </div>
        </div>
      </div>

      <div class="ops__block">
        <div class="ops__label"><.icon name={:terminal} size={14} /> Pipeline</div>
        <ol class="pipeline">
          <li :if={!@pending} class="pipeline__idle">Identity — no operations queued</li>
          <li :for={step <- operation_summary(@operations)}>
            <span class="pipeline__dot"></span>{step}
          </li>
        </ol>
      </div>

      <footer class="ops__foot">
        <button
          class="btn btn--ghost"
          phx-click="reset_operations"
          disabled={!@pending || @processing != nil}
        >
          <.icon name={:refresh} size={14} /> Reset
        </button>
        <button
          class="btn btn--primary"
          phx-click="apply_changes"
          disabled={!@image || !@pending || @processing != nil}
        >
          <.icon name={:check} size={14} /> Apply Changes
        </button>
      </footer>
    </section>
    """
  end

  # -------------------------------------------------------------------------
  # Private display helpers (used by the templates above)
  # -------------------------------------------------------------------------

  defp folder_active(active, folder),
    do: if(active && active.id == folder.id, do: " folder--active", else: "")

  defp folder_icon(%{kind: :uploads}), do: :upload
  defp folder_icon(%{kind: :subfolder}), do: :folder
  defp folder_icon(_folder), do: :images
  defp toggle_class(current, current), do: " btn--active"
  defp toggle_class(_current, _expected), do: ""
  defp list_class(:list), do: "imagelist--list"
  defp list_class(_grid), do: "imagelist--grid"
  defp card_active(nil, _item), do: ""
  defp card_active(%{id: id}, %{id: id}), do: " card--active"
  defp card_active(_image, _item), do: ""
  defp thumb_active(nil, _item), do: ""
  defp thumb_active(%{id: id}, %{id: id}), do: " thumb--active"
  defp thumb_active(_image, _item), do: ""
  defp sort_label(:name), do: "Name"
  defp sort_label(:size), do: "Size"
  defp sort_label(:modified), do: "Modified"
  defp sort_label(other), do: other |> to_string() |> String.capitalize()
  defp direction_label(:asc), do: "Asc"
  defp direction_label(:desc), do: "Desc"
  defp direction_label(other), do: other |> to_string() |> String.capitalize()
  defp rotation_label(0), do: "0°"
  defp rotation_label(angle), do: "#{angle}°"
  defp zoom_label(1.0), do: "1:1"
  defp zoom_label(zoom), do: "#{round(zoom * 100)}%"
  defp alpha_label(true), do: "Yes"
  defp alpha_label(_), do: "No"
  defp shorten_path(path, max), do: Fmt.shorten_path(path, max)

  defp upload_error_message({ref, reason}) when is_binary(ref),
    do: upload_error_message(reason)

  defp upload_error_message(:too_large), do: "That file exceeds the upload limit."
  defp upload_error_message(:too_many_files), do: "Too many files selected."
  defp upload_error_message(:not_accepted), do: "That file type is not accepted."
  defp compare_size(nil, _metadata), do: "n/a"

  defp compare_size(%{bytes: bytes}, %{bytes: source})
       when is_integer(bytes) and is_integer(source) do
    ImageManipulator.Fmt.percent((bytes - source) / max(source, 1) * 100)
  end

  defp compare_size(_result, _metadata), do: "n/a"
  # -------------------------------------------------------------------------
  # Output gallery
  # -------------------------------------------------------------------------

  @doc """
  Output gallery: the real files written by the last "Apply Changes" run.

  Reads: `outputs`, `current_output`, `processing`, `thumb_width`.
  """
  def outputs_panel(assigns) do
    ~H"""
    <article class="card-panel outputs" id="output-panel">
      <header class="card-panel__head">
        <.icon name={:layers} size={15} />
        <span>Output</span>
        <span :if={@outputs != []} class="badge badge--muted">{length(@outputs)} files</span>
        <span :if={@outputs == []} class="badge badge--muted">empty</span>
        <span :if={@processing == :apply} class="badge badge--warn">
          <.icon name={:refresh} size={12} /> writing files
        </span>
      </header>

      <p class="outputs__sub">Preview of modified image will appear here</p>

      <div :if={@outputs == []} class="outputs__empty">
        <.empty_state
          icon={:download}
          title="No outputs yet"
          body="Queue rotate, invert or a format conversion on the right, then press Apply Changes — every card below is a real file written into this session's workspace."
        />
      </div>

      <div :if={@outputs != []} class="outputs__grid">
        <article :for={entry <- @outputs} class={"outcard" <> output_active(@current_output, entry)}>
          <button
            type="button"
            class="outcard__pick"
            phx-click="preview_output"
            phx-value-id={entry.id}
            title={"Preview #{entry.label}"}
          >
            <img src={entry.thumb_url} alt={entry.label} loading="lazy" decoding="async" />
            <span :if={entry.applied?} class="outcard__flag">
              <.icon name={:check} size={12} /> applied
            </span>
          </button>

          <div class="outcard__body">
            <span class="outcard__label">{entry.label}</span>
            <span class="outcard__meta">
              {entry.format_label} · {Fmt.dimensions(entry.width, entry.height)}
            </span>
            <span class="outcard__meta">
              {Fmt.bytes(entry.bytes)}{if entry.quality, do: " · q#{entry.quality}", else: ""}
            </span>

            <div class="outcard__actions">
              <button
                type="button"
                class="btn btn--soft btn--sm"
                phx-click="preview_output"
                phx-value-id={entry.id}
              >
                <.icon name={:eye} size={13} /> Preview
              </button>
              <a class="btn btn--icon btn--sm" href={entry.download_url} title="Download this file">
                <.icon name={:download} size={13} />
              </a>
              <button
                :if={entry.kind != :original}
                type="button"
                class="btn btn--icon btn--sm"
                phx-click="remove_output"
                phx-value-id={entry.id}
                title="Delete this generated file"
              >
                <.icon name={:trash} size={13} />
              </button>
            </div>
          </div>
        </article>
      </div>
    </article>
    """
  end

  # -------------------------------------------------------------------------
  # Save panel
  # -------------------------------------------------------------------------

  @doc """
  "Save As" panel — writes the selected output to disk.

  Reads: `save_form`, `outputs`, `current_output`, `preview`, `processing`,
  `saved`, `save_error`, `settings`.
  """
  def save_panel(assigns) do
    ~H"""
    <section class="panel save" id="save-panel">
      <header class="panel__head">
        <div class="panel__title">
          <.icon name={:save} size={16} />
          <span>Save As</span>
        </div>
        <span :if={@saved} class="badge badge--ok"><.icon name={:check} size={12} /> saved</span>
        <span :if={!@saved} class="badge badge--muted">not saved</span>
      </header>

      <form class="save__form" phx-change="update_save_form" phx-submit="save_output">
        <div class="field">
          <label class="field__label" for="save-file-name">
            <.icon name={:image} size={13} /> File Name
          </label>
          <input
            id="save-file-name"
            class="field__input"
            type="text"
            name="file_name"
            value={@save_form.file_name}
            placeholder="mountain_edited.jpg"
            autocomplete="off"
            spellcheck="false"
          />
        </div>

        <div class="field">
          <label class="field__label" for="save-location">
            <.icon name={:folder} size={13} /> Save Location
          </label>
          <input
            id="save-location"
            class="field__input field__input--mono"
            type="text"
            name="location"
            value={@save_form.location}
            placeholder={@settings.output_dir}
            autocomplete="off"
            spellcheck="false"
          />
        </div>

        <div class="save__row">
          <span class="save__row-key">Saving</span>
          <span class="save__row-value">
            {save_source_label(@current_output, @preview, @outputs)}
          </span>
        </div>

        <p class="save__hint">
          <strong>Higher quality = larger file size.</strong>
          A <code>.jpg</code>, <code>.webp</code>
          or <code>.png</code>
          destination is re-encoded by
          ImageMagick; every other extension is written byte for byte. Relative paths resolve inside <code><%= shorten_path(@settings.output_dir, 34) %></code>.
        </p>

        <button
          type="submit"
          class="btn btn--primary btn--full"
          disabled={@processing != nil or not saveable?(@current_output, @preview)}
        >
          <.icon name={:save} size={15} /> Save Image
        </button>
      </form>

      <div :if={@save_error} class="alert alert--error">
        <.icon name={:alert} size={14} />
        <span>{@save_error}</span>
      </div>

      <div :if={@saved} class="alert alert--ok">
        <.icon name={:check} size={14} />
        <span>
          ✓ Image saved successfully — <strong>{@saved.name}</strong>
          ({Fmt.bytes(@saved.bytes)}) in <code>{shorten_path(@saved.dir, 34)}</code>
        </span>
      </div>

      <div :if={!@save_error && !@saved} class="card-panel__idle">
        Nothing saved in this session yet.
      </div>
    </section>
    """
  end

  # -------------------------------------------------------------------------
  # Home dashboard
  # -------------------------------------------------------------------------

  @doc """
  Landing dashboard: library statistics, recent work and quick actions.

  Reads: `library_stats`, `recent`, `folders`, `env`, `image`, `active_folder`,
  `thumb_width`, `session`, `session_files`, `session_bytes`.
  """
  def home_view(assigns) do
    ~H"""
    <div class="home">
      <section class="panel home__hero">
        <div class="home__intro">
          <h1 class="home__title">ImageManipulator</h1>
          <p class="home__tagline">Transform · Enhance · Save</p>
          <p class="home__lede">
            A server-side image workflow built on Phoenix LiveView. Rotation, colour
            inversion and JPEG compression are performed by ImageMagick on the
            Elixir backend — the browser only ever receives finished files.
          </p>
        </div>

        <div class="home__actions">
          <button class="btn btn--primary" phx-click="nav" phx-value-view="editor">
            <.icon name={:images} size={15} /> Open the studio
          </button>
          <button class="btn btn--ghost" phx-click="nav" phx-value-view="settings">
            <.icon name={:settings} size={15} /> Settings
          </button>
        </div>

        <div class="home__stats">
          <.stat
            icon={:image}
            label="Indexed images"
            value={to_string(@library_stats.images)}
            hint={"in #{@library_stats.folders} folders"}
          />
          <.stat
            icon={:database}
            label="Library size"
            value={Fmt.bytes(@library_stats.bytes)}
            hint={"#{@library_stats.roots} configured roots"}
          />
          <.stat
            icon={:folder}
            label="Browseable folders"
            value={to_string(length(@folders))}
            hint="roots, sub-folders and uploads"
          />
          <.stat
            icon={:cpu}
            label="Processing backend"
            value={backend_label(@env)}
            hint={"writes: " <> Enum.join(Enum.take(@env.writable_formats, 4), ", ")}
          />
          <.stat
            icon={:save}
            label="Session workspace"
            value={@session_bytes}
            hint={"#{@session_files} files this session"}
          />
        </div>
      </section>

      <section class="panel home__recent">
        <header class="panel__head">
          <div class="panel__title">
            <.icon name={:sparkles} size={16} />
            <span>Recently modified</span>
          </div>
          <span class="badge badge--muted">{length(@recent)} shown</span>
        </header>

        <div :if={@recent == []} class="home__empty">
          <.empty_state
            icon={:image}
            title="No images indexed"
            body="Add files to priv/images (or configure :library_roots) and rescan the library."
          />
        </div>

        <div :if={@recent != []} class="home__grid">
          <button
            :for={item <- @recent}
            class="card card--tile"
            phx-click="select_image"
            phx-value-id={item.id}
            title={item.path}
          >
            <span class="card__thumb">
              <img
                src={Workspace.media_url(item.path, width: @thumb_width)}
                alt={item.name}
                loading="lazy"
              />
              <span class="card__format">{item.format_label}</span>
            </span>
            <span class="card__body">
              <span class="card__name">{item.name}</span>
              <span class="card__meta">{Fmt.bytes(item.bytes)} · {Fmt.ago(item.mtime)}</span>
            </span>
          </button>
        </div>
      </section>
    </div>
    """
  end

  # -------------------------------------------------------------------------
  # Settings panel
  # -------------------------------------------------------------------------

  @doc """
  Settings: output directory, JPEG quality, thumbnail size and overwrite policy.

  Reads: `settings`, `settings_error`, `settings_persisted?`, `env`.
  """
  def settings_panel(assigns) do
    ~H"""
    <section class="panel settings">
      <header class="panel__head">
        <div class="panel__title">
          <.icon name={:settings} size={16} />
          <span>Settings</span>
        </div>
        <span class={if @settings_persisted?, do: "badge badge--ok", else: "badge badge--muted"}>
          {if @settings_persisted?, do: "saved to disk", else: "defaults"}
        </span>
      </header>

      <form class="settings__form" phx-submit="save_settings">
        <div class="field">
          <label class="field__label" for="settings-output-dir">
            <.icon name={:folder} size={13} /> Output directory
          </label>
          <input
            id="settings-output-dir"
            class="field__input field__input--mono"
            type="text"
            name="output_dir"
            value={@settings.output_dir}
            spellcheck="false"
          />
          <span class="field__hint">
            Absolute paths are allowed; relative paths resolve against the project root.
          </span>
        </div>

        <div class="settings__grid">
          <div class="field">
            <label class="field__label" for="settings-jpg-quality">
              <.icon name={:palette} size={13} /> JPEG quality
            </label>
            <input
              id="settings-jpg-quality"
              class="field__input"
              type="number"
              name="jpg_quality"
              value={@settings.jpg_quality}
              min="5"
              max="100"
            />
            <span class="field__hint">5 – 100</span>
          </div>

          <div class="field">
            <label class="field__label" for="settings-thumbnail-size">
              <.icon name={:grid} size={13} /> Thumbnail size
            </label>
            <input
              id="settings-thumbnail-size"
              class="field__input"
              type="number"
              name="thumbnail_size"
              value={@settings.thumbnail_size}
              min="48"
              max="512"
            />
            <span class="field__hint">48 – 512 px</span>
          </div>
        </div>

        <label class="check">
          <input type="checkbox" name="overwrite" value="true" checked={@settings.overwrite} />
          <span>
            <span class="check__label">Overwrite existing files</span>
            <span class="check__hint">
              When off, saving never replaces a file that already exists.
            </span>
          </span>
        </label>

        <div :if={@settings_error} class="alert alert--error">
          <.icon name={:alert} size={14} /> <span>{@settings_error}</span>
        </div>

        <div class="settings__actions">
          <button type="submit" class="btn btn--primary">
            <.icon name={:check} size={14} /> Save Settings
          </button>
          <button type="button" class="btn btn--ghost" phx-click="reset_settings">
            <.icon name={:refresh} size={14} /> Restore Defaults
          </button>
        </div>
      </form>

      <div class="card-panel">
        <header class="card-panel__head">
          <.icon name={:cpu} size={15} />
          <span>Backend</span>
        </header>
        <div class="metagrid">
          <.meta_row label="Engine" value={backend_label(@env)} />
          <.meta_row label="convert" value={@env.convert || "not found"} mono />
          <.meta_row label="identify" value={@env.identify || "not found"} mono />
          <.meta_row
            label="Writable formats"
            value={Enum.join(Enum.take(@env.writable_formats, 8), ", ")}
          />
          <.meta_row label="Upload limit" value={Fmt.bytes(@max_upload_size)} />
        </div>
      </div>
    </section>
    """
  end

  # -------------------------------------------------------------------------
  # Private helpers for the output, save, home and settings panels
  # -------------------------------------------------------------------------

  defp output_active(nil, _entry), do: ""
  defp output_active(%{id: id}, %{id: id}), do: " outcard--active"
  defp output_active(_current, _entry), do: ""

  defp save_source_label(nil, nil, _outputs), do: "nothing processed yet"
  defp save_source_label(nil, %{processed?: false}, _outputs), do: "the untouched original"

  defp save_source_label(%{label: label, format_label: fmt, quality: q}, _preview, _outputs) do
    quality = if q, do: " · #{q}%", else: ""
    "#{label} (#{fmt}#{quality}) — selected output"
  end

  defp save_source_label(%{label: label}, _preview, _outputs), do: "#{label} (selected output)"

  defp save_source_label(nil, %{processed?: true, path: path}, outputs)
       when is_list(outputs) and is_binary(path) do
    case Enum.find(outputs, &(&1.path == path)) do
      %{label: label, format_label: fmt, quality: q} ->
        quality = if q, do: " · #{q}%", else: ""
        "#{label} (#{fmt}#{quality})"

      _other ->
        "the latest preview"
    end
  end

  @doc """
  Gallery of the images saved during this session.

  Thumbnails are built from the stored path with `Workspace.media_url/2`, the
  same signed `/media/:token` source the Home images list uses, so a file saved
  into any output directory renders exactly like a library image.

  Reads: `saved_images`, `thumb_width`, `lightbox_image_id`.
  """
  def my_images_view(assigns) do
    ~H"""
    <section class="panel my-images panels">
      <header class="panel__head">
        <div class="panel__title">
          <.icon name={:images} size={16} />
          <span>My Images</span>
          <span :if={@saved_images != []} class="badge badge--muted">{length(@saved_images)}</span>
        </div>
      </header>

      <div :if={@saved_images == []} class="imagelist imagelist--empty">
        <.empty_state
          icon={:image}
          title="No images saved yet"
          body="Use Save Image after editing to add images here."
        />
      </div>

      <div :if={@saved_images != []} class="my-images__grid">
        <div
          :for={item <- @saved_images}
          class="my-images__card"
        >
          <div class="my-images__card__thumb" phx-click="open_lightbox" phx-value-id={item.id}>
            <img
              src={Workspace.media_url(item.path, width: @thumb_width)}
              alt={item.name}
              loading="lazy"
              decoding="async"
            />
            <span class="my-images__card__format">{item.format_label}</span>
            <div class="my-images__card__overlay">
              <button class="btn btn--icon" phx-click="edit_image" phx-value-id={item.id} title="Edit">
                <.icon name={:edit} size={16} />
              </button>
              <button class="btn btn--icon" phx-click="rename_image" phx-value-id={item.id} title="Rename">
                <.icon name={:edit_2} size={16} />
              </button>
              <button class="btn btn--icon btn--danger" phx-click="delete_image" phx-value-id={item.id} data-confirm="Delete?" title="Delete">
                <.icon name={:trash} size={16} />
              </button>
            </div>
          </div>
          <div class="my-images__card__body">
            <span class="my-images__card__name">{item.name}</span>
            <span class="my-images__card__meta">
              {Fmt.bytes(item.bytes)} · {Fmt.ago(item.mtime)}
            </span>
          </div>
        </div>
      </div>

      <%= if @lightbox_image_id do %>
        <div class="lightbox lightbox--open" id="lightbox">
          <button
            class="lightbox__close"
            phx-click="close_lightbox"
            aria-label="Close"
            title="Close"
          >
            <.icon name={:x} size={20} />
          </button>

          <button
            class="lightbox__nav lightbox__nav--prev"
            phx-click="prev_lightbox"
            aria-label="Previous"
            title="Previous"
          >
            <.icon name={:chevron_left} size={28} />
          </button>

          <div class="lightbox__image-wrap">
            <img
              src={current_lightbox_url(@saved_images, @lightbox_image_id)}
              alt="Lightbox view"
              class="lightbox__img"
            />
          </div>

          <button
            class="lightbox__nav lightbox__nav--next"
            phx-click="next_lightbox"
            aria-label="Next"
            title="Next"
          >
            <.icon name={:chevron_right} size={28} />
          </button>
        </div>
      <% end %>
    </section>
    """
  end

  defp current_lightbox_url(images, id) do
    case Enum.find(images, &(&1.id == id)) do
      nil -> nil
      item -> Workspace.media_url(item.path)
    end
  end

  defp saveable?(current_output, preview) do
    current_output != nil or (preview != nil and preview.processed?)
  end
end
