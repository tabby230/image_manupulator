defmodule ImageManipulatorWeb.StudioComponents do
  @moduledoc """
  Function components that make up the studio UI.

  Two flavours live here:

    * small, reusable primitives with declared attributes (`icon/1`, `badge/1`,
      `switch/1`, `meta_row/1`, ...)
    * page sections that receive the LiveView's assigns as a whole
      (`app_header/1`, `library_panel/1`, `stage/1`, ...). Their `@doc` lists
      every assign they read.

  Every icon is an inline SVG on `currentColor`, so the CSS gradient background
  shows through and no icon font or external asset is required.
  """

  use Phoenix.Component

  alias ImageManipulator.{Fmt, ImageProcessor, Operations}

  # ---------------------------------------------------------------------------
  # Icons
  # ---------------------------------------------------------------------------

  @icons %{
    home: "M3 10.5 12 3l9 7.5M5 9.5V21h5v-6h4v6h5V9.5",
    images: "M4 5h16v12H4zM4 17l4.5-4.5 3 3L15 12l5 5M14.5 8.5h.01M9 5 7 2.5 3 5.5",
    sliders: "M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0M14 6v0M8 12v0",
    settings:
      "M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2 2 2 0 1 1-4 0 1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.7 1.7 0 0 0 4.6 15a2 2 0 1 1 0-4 1.7 1.7 0 0 0 1.2-2.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.7 1.7 0 0 0 11.5 4a2 2 0 1 1 4 0 1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1A1.7 1.7 0 0 0 19.4 11a2 2 0 1 1 0 4Z",
    folder:
      "M3 7.5A2 2 0 0 1 5 5.5h3.6l1.8 2.2H19a2 2 0 0 1 2 2v8.8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z",
    search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14ZM20 20l-4-4",
    grid: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
    list: "M4 6h16M4 12h16M4 18h16",
    chevron_left: "M15 5l-7 7 7 7",
    chevron_right: "M9 5l7 7-7 7",
    chevron_down: "M6 9l6 6 6-6",
    rotate_cw: "M20 12a8 8 0 1 1-2.7-6M20 4v5h-5",
    rotate_ccw: "M4 12a8 8 0 1 0 2.7-6M4 4v5h5",
    rotate90: "M7 17h8a4 4 0 0 0 4-4V9M7 17l3-3M7 17l3 3M8 3h5v5H8z",
    rotate180: "M12 20a8 8 0 1 1 8-8M20 4v4h-4M7 9h10M7 9l3-3M7 9l3 3",
    rotate270: "M17 7H9a4 4 0 0 0-4 4v4M17 7l-3 3M17 7l-3-3M11 21H6v-5h5z",
    contrast: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18ZM12 3v18",
    convert: "M4 8h13l-3-3M20 16H7l3 3",
    download: "M12 4v11m0 0 4-4m-4 4-4-4M5 20h14",
    save: "M5 4h11l3 3v13H5zM8 4v6h7V4M8 20v-6h8v6",
    upload: "M12 20V9m0 0 4 4m-4-4-4 4M5 4h14",
    refresh: "M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6",
    check: "M5 13l4 4L19 7",
    x: "M6 6l12 12M18 6 6 18",
    alert: "M12 3 2 20h20L12 3Zm0 6v5m0 3h.01",
    info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-13h.01M12 11v6",
    clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-13v5l3.5 2",
    cpu: "M8 8h8v8H8zM5 5h14v14H5zM3 9h2M3 15h2M19 9h2M19 15h2M9 3v2M15 3v2M9 19v2M15 19v2",
    database:
      "M12 8c4.4 0 8-1.1 8-2.5S16.4 3 12 3 4 4.1 4 5.5 7.6 8 12 8Zm8-2.5v13C20 20 16.4 21 12 21s-8-1-8-2.5v-13",
    image: "M4 5h16v14H4zM4 15l4-4 3.5 3.5L15 11l5 5M14 9h.01",
    eye:
      "M2 12s3.6-6 10-6 10 6 10 6-3.6 6-10 6-10-6-10-6Zm10 2.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z",
    maximize: "M4 9V4h5M20 15v5h-5M15 4h5v5M9 20H4v-5",
    minimize: "M9 4v5H4M15 20v-5h5M20 9h-5V4M4 15h5v5",
    zoom_in: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14ZM20 20l-4-4M11 8v6M8 11h6",
    zoom_out: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14ZM20 20l-4-4M8 11h6",
    fit: "M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5M9 9h6v6H9z",
    trash: "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6",
    sort: "M7 4v16m0 0-3-3m3 3 3-3M17 20V4m0 0-3 3m3-3 3 3",
    layers: "M12 3 3 8l9 5 9-5-9-5ZM3 13l9 5 9-5M3 17.5l9 5 9-5",
    shield: "M12 3 5 6v6c0 4.2 2.9 7.6 7 9 4.1-1.4 7-4.8 7-9V6l-7-3Zm-2.5 8.5 2 2 4-4",
    sparkles:
      "M12 3l1.6 4.6L18 9l-4.4 1.4L12 15l-1.6-4.6L6 9l4.4-1.4L12 3Zm7 10 .8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z",
    terminal: "M4 5h16v14H4zM7.5 9.5l2.5 2.5-2.5 2.5M12.5 15H17",
    palette:
      "M12 21a9 9 0 1 1 0-18c4.5 0 8 3 8 6.5 0 2.5-2 4-4.5 4H14a2 2 0 0 0-1.4 3.4A1.6 1.6 0 0 1 12 21ZM7.5 10h.01M10.5 7.5h.01M14.5 7h.01M17 9.5h.01"
  }

  attr :name, :atom, required: true
  attr :class, :string, default: "icon"
  attr :size, :integer, default: 18

  @doc """
  Renders one of the built-in inline SVG icons.
  """
  def icon(assigns) do
    assigns = assign(assigns, :path, Map.get(@icons, assigns.name, @icons.info))

    ~H"""
    <svg
      class={@class}
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d={@path} />
    </svg>
    """
  end

  @doc """
  Names of the icons available to `icon/1` (used by tests).
  """
  def icon_names, do: @icons |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  # ---------------------------------------------------------------------------
  # Primitives
  # ---------------------------------------------------------------------------

  attr :variant, :string, default: "muted"
  attr :icon, :atom, default: nil
  slot :inner_block, required: true

  @doc """
  Small status pill. Variants: `muted`, `ok`, `warn`, `danger`, `accent`.
  """
  def badge(assigns) do
    ~H"""
    <span class={"badge badge--#{@variant}"}>
      <.icon :if={@icon} name={@icon} size={13} />
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :icon, :atom, default: nil
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  @doc """
  One stat readout: icon, label, value.
  """
  def stat(assigns) do
    ~H"""
    <div class="stat">
      <.icon :if={@icon} name={@icon} size={16} class="stat__icon" />
      <div class="stat__body">
        <span class="stat__label">{@label}</span>
        <span class="stat__value">{@value}</span>
        <span :if={@hint} class="stat__hint">{@hint}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  @doc """
  A metadata row (label on the left, value on the right).
  """
  def meta_row(assigns) do
    ~H"""
    <div class="meta-row">
      <span class="meta-row__key">{@label}</span>
      <span class={"meta-row__value#{if @mono, do: " meta-row__value--mono", else: ""}"}>
        {@value}
      </span>
    </div>
    """
  end

  attr :icon, :atom, required: true
  attr :title, :string, required: true
  attr :body, :string, default: nil
  slot :inner_block

  @doc """
  Placeholder shown when a panel has nothing to display.
  """
  def empty_state(assigns) do
    ~H"""
    <div class="empty">
      <.icon name={@icon} size={22} class="empty__icon" />
      <p class="empty__title">{@title}</p>
      <p :if={@body} class="empty__body">{@body}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :size, :integer, default: 18
  attr :label, :string, default: nil

  @doc """
  Spinner shown while a server-side ImageMagick job is running.
  """
  def spinner(assigns) do
    ~H"""
    <span class="spinner" role="status" aria-live="polite">
      <span class="spinner__dot" style={"width: #{@size}px; height: #{@size}px"}></span>
      <span :if={@label} class="spinner__label">{@label}</span>
    </span>
    """
  end

  attr :active, :boolean, required: true
  attr :event, :string, required: true
  attr :param, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  @doc """
  One option inside a segmented control.
  """
  def segment(assigns) do
    ~H"""
    <button
      type="button"
      class={"seg__item#{if @active, do: " seg__item--active", else: ""}"}
      phx-click={@event}
      phx-value-param={@param}
      disabled={@disabled}
      aria-pressed={to_string(@active)}
    >
      {@label}
    </button>
    """
  end

  attr :on, :boolean, required: true
  attr :event, :string, required: true
  attr :param, :string, default: "toggle"
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :disabled, :boolean, default: false

  @doc """
  Accessible on/off switch used for the "Invert Colours" control.
  """
  def switch(assigns) do
    ~H"""
    <div class={"switch#{if @on, do: " switch--on", else: ""}#{if @disabled, do: " switch--disabled", else: ""}"}>
      <div class="switch__text">
        <span class="switch__label">{@label}</span>
        <span :if={@hint} class="switch__hint">{@hint}</span>
      </div>
      <button
        type="button"
        class="switch__control"
        role="switch"
        aria-checked={to_string(@on)}
        aria-label={@label}
        disabled={@disabled}
        phx-click={@event}
        phx-value-param={@param}
      >
        <span class="switch__thumb"></span>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Formatting wrappers (keeps templates readable)
  # ---------------------------------------------------------------------------

  @doc "Formats a byte count."
  def bytes(value), do: Fmt.bytes(value)

  @doc "Formats pixel dimensions."
  def dimensions(width, height), do: Fmt.dimensions(width, height)

  @doc "Formats a signed percentage."
  def percent(value), do: Fmt.percent(value)

  @doc "Formats a relative time."
  def ago(datetime), do: Fmt.ago(datetime)

  @doc "Formats an absolute timestamp."
  def datetime(value), do: Fmt.datetime(value)

  @doc "Shortens a long path for display in narrow panels."
  def shorten_path(path), do: Fmt.shorten_path(path)

  @doc "Display label for an ImageMagick format code."
  def format_label(value), do: ImageProcessor.format_label(value)

  @doc "Labels describing the pending pipeline."
  def operation_summary(%Operations{} = operations), do: Operations.summary(operations)

  @doc "True when the pipeline would change anything."
  def operations_pending?(%Operations{} = operations), do: Operations.pending?(operations)
end
