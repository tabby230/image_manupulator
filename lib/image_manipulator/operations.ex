defmodule ImageManipulator.Operations do
  @moduledoc """
  The image pipeline the user is composing in the right hand panel.

  This struct is pure data - it never touches the disk. `ImageManipulator.ImageProcessor`
  turns it into actual ImageMagick work, which keeps the UI trivially testable and
  means a change of operations is always expressible as a diff.

  Rotation is stored as an absolute value (0, 90, 180, 270) because the panel
  exposes discrete "Rotate 90/180/270" buttons, while `rotate/2` supports the
  incremental left/right nudges.
  """

  @rotations [0, 90, 180, 270]
  @formats [:png, :webp, :jpg]
  # Compression strength -> quality factor. Higher compression removes more
  # detail, so it maps to a *lower* quality factor.
  @compression %{low: 90, medium: 75, high: 55}

  @enforce_keys [:rotation, :invert, :format, :compression]
  defstruct rotation: 0, invert: false, format: :jpg, compression: :medium

  @type format :: :png | :webp | :jpg
  @type compression :: :low | :medium | :high
  @type t :: %__MODULE__{
          rotation: 0 | 90 | 180 | 270,
          invert: boolean(),
          format: format(),
          compression: compression()
        }

  @doc "A pristine pipeline: nothing to do."
  @spec new() :: t()
  def new, do: %__MODULE__{rotation: 0, invert: false, format: :jpg, compression: :medium}

  @doc "Valid rotations, in the order they appear in the UI."
  @spec rotations() :: [0 | 90 | 180 | 270]
  def rotations, do: @rotations

  @doc "Selectable conversion targets."
  @spec formats() :: [format()]
  def formats, do: @formats

  @doc "Compression levels exposed by the UI."
  @spec compression_levels() :: [compression()]
  def compression_levels, do: [:low, :medium, :high]

  @doc """
  Sets an absolute rotation.
  """
  @spec set_rotation(t(), integer()) :: {:ok, t()} | {:error, String.t()}
  def set_rotation(%__MODULE__{} = ops, degrees) when degrees in @rotations,
    do: {:ok, %{ops | rotation: degrees}}

  def set_rotation(%__MODULE__{}, degrees),
    do: {:error, "#{degrees}° is not a supported rotation."}

  @doc """
  Rotates further, e.g. `rotate(ops, -90)` after a "rotate left" click.

  The result is normalised into 0..270.
  """
  @spec rotate(t(), integer()) :: t()
  def rotate(%__MODULE__{} = ops, degrees) when is_integer(degrees) do
    %{ops | rotation: Integer.mod(ops.rotation + degrees, 360)}
  end

  @doc """
  Turns colour inversion on or off.
  """
  @spec set_invert(t(), boolean()) :: t()
  def set_invert(%__MODULE__{} = ops, value), do: %{ops | invert: value == true}

  @doc """
  Shortcut used by the toggle control.
  """
  @spec toggle_invert(t()) :: t()
  def toggle_invert(%__MODULE__{} = ops), do: %{ops | invert: not ops.invert}

  @doc """
  Chooses the output format (`:jpg` is the default; PNG is lossless).
  """
  @spec set_format(t(), format()) :: {:ok, t()} | {:error, String.t()}
  def set_format(%__MODULE__{} = ops, format) when format in @formats,
    do: {:ok, %{ops | format: format}}

  def set_format(%__MODULE__{}, format),
    do: {:error, "Unsupported output format: #{inspect(format)}."}

  @doc """
  Chooses a compression level.
  """
  @spec set_compression(t(), compression()) :: {:ok, t()} | {:error, String.t()}
  def set_compression(%__MODULE__{} = ops, level) when is_map_key(@compression, level),
    do: {:ok, %{ops | compression: level}}

  def set_compression(%__MODULE__{}, level),
    do: {:error, "Unsupported compression level: #{inspect(level)}."}

  @doc """
  Numeric JPEG quality for a compression level.
  """
  @spec quality(compression() | integer()) :: integer()
  def quality(level) when is_integer(level), do: level
  def quality(level) when is_map_key(@compression, level), do: Map.fetch!(@compression, level)

  @doc """
  Quality used for the pipeline, falling back to the configured default when the
  user has not converted the image.
  """
  @spec jpg_quality(t()) :: integer()
  def jpg_quality(%__MODULE__{compression: level}), do: quality(level)

  @doc """
  True when the selected format honours a compression level (JPEG and WebP);
  PNG is lossless and ignores it.
  """
  @spec compressible?(t()) :: boolean()
  def compressible?(%__MODULE__{format: :jpg}), do: true
  def compressible?(%__MODULE__{format: :webp}), do: true
  def compressible?(%__MODULE__{format: :png}), do: false

  @doc """
  True when the pipeline would change the image or its container.
  """
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{} = ops), do: ops.rotation != 0 or ops.invert or ops.format != :jpg

  @doc """
  Human readable list of the steps, used in the output and save panels.
  """
  @spec summary(t()) :: [String.t()]
  def summary(%__MODULE__{} = ops) do
    []
    |> maybe_append(ops.rotation != 0, "Rotate #{ops.rotation}°")
    |> maybe_append(ops.invert, "Invert colours")
    |> maybe_append(
      ops.format == :webp,
      "Convert to WebP · #{compression_label(ops.compression)} compression (#{jpg_quality(ops)}% quality)"
    )
    |> maybe_append(ops.format == :png, "Convert to PNG · lossless")
  end

  @doc """
  Short label for the requested output format.
  """
  @spec format_label(t()) :: String.t()
  def format_label(%__MODULE__{format: :jpg}), do: "JPEG"
  def format_label(%__MODULE__{format: :png}), do: "PNG"
  def format_label(%__MODULE__{format: :webp}), do: "WebP"

  @doc """
  Extension the pipeline writes.
  """
  @spec output_extension(t()) :: String.t()
  def output_extension(%__MODULE__{format: format}), do: "." <> Atom.to_string(format)

  @doc """
  Label for a compression level, e.g. `:high -> "High"`.
  """
  @spec compression_label(compression()) :: String.t()
  def compression_label(level) when is_map_key(@compression, level) do
    level |> Atom.to_string() |> String.capitalize()
  end

  defp maybe_append(list, false, _label), do: list
  defp maybe_append(list, true, label), do: list ++ [label]
end
