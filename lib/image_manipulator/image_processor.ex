defmodule ImageManipulator.ImageProcessor do
  @moduledoc """
  Real, server-side image processing.

  Everything here shells out to **ImageMagick** through the `mogrify` Elixir
  package (no NIFs, no compiler step at runtime) and every function returns
  `{:ok, value}` or `{:error, human_readable_reason}` - no exceptions leak into
  the LiveView.

  The processing primitives follow the shape requested by the product spec:

    * `load_image/1`     - validate and open a source image
    * `rotate/2`         - rotate by 0/90/180/270 degrees
    * `invert/1`         - photographic negative (`-negate`)
    * `convert_to_jpg/2` - flatten transparency onto white, set JPEG quality
    * `convert_to_webp/2` - keep alpha, set WebP quality
    * `convert_to_png/2`  - lossless PNG output (alpha preserved)
    * `save_image/2`     - write the result to disk (optionally refusing to
                           overwrite an existing file)

  On top of those, `process/3` runs a whole `ImageManipulator.Operations`
  pipeline and `thumbnail/3` produces cached previews for the browser.
  """

  require Logger

  alias ImageManipulator.ImageProcessor.Result
  alias ImageManipulator.Operations

  @image_extensions ~w(.jpg .jpeg .png .gif .webp .bmp .tif .tiff .avif)
  @rotations [0, 90, 180, 270]
  @max_thumbnail_px 2_048
  @thumbnail_quality 82

  # Fields requested from ImageMagick's identify. Order matters: it is the order
  # `parse_info/2` splits on.
  @identify_fields "'%m|%w|%h|%z|%[colorspace]|%[orientation]|%[opaque]|%b|%[channels]'"

  # ---------------------------------------------------------------------------
  # Capabilities
  # ---------------------------------------------------------------------------

  @doc """
  File extensions the application treats as images.
  """
  @spec image_extensions() :: [String.t()]
  def image_extensions, do: @image_extensions

  @doc """
  True when the ImageMagick command line tools this module depends on are
  reachable. The UI surfaces this so a missing install is obvious instead of
  silently breaking every operation.
  """
  @spec available?() :: boolean()
  def available?, do: convert_path() != nil and identify_path() != nil

  @doc """
  Probes the ImageMagick installation: tool paths, version banner and the
  formats that can actually be *written* on this machine.
  """
  @spec environment() :: map()
  def environment do
    convert = convert_path()
    identify = identify_path()

    %{
      available?: convert != nil and identify != nil,
      convert: convert,
      identify: identify,
      version: version(),
      backend: "ImageMagick via mogrify #{version_of_mogrify()}",
      writable_formats: writable_formats()
    }
  end

  @doc """
  Version banner of the `convert` binary, or `nil` when unavailable.
  """
  @spec version() :: String.t() | nil
  def version do
    case convert_path() do
      nil ->
        nil

      convert ->
        case System.cmd(convert, ["-version"], stderr_to_stdout: true) do
          {output, 0} -> output |> String.split("\n", parts: 2) |> List.first() |> String.trim()
          {_output, _code} -> nil
        end
    end
  rescue
    _ -> nil
  end

  @doc """
  Image formats ImageMagick reports as writable on this host.
  """
  @spec writable_formats() :: [String.t()]
  def writable_formats do
    case convert_path() do
      nil ->
        []

      convert ->
        case System.cmd(convert, ["-list", "format"], stderr_to_stdout: true) do
          {output, 0} -> parse_formats(output)
          {_output, _code} -> []
        end
    end
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # load_image/1
  # ---------------------------------------------------------------------------

  @doc """
  Opens an image for processing.

  Accepts an already-resolved `{:ok, image}` / `{:error, reason}` tuple so it can
  be chained, or a path. Paths are validated first, which produces much friendlier
  errors than letting ImageMagick fail.
  """
  @spec load_image(Path.t() | {:ok, term()} | {:error, term()}) ::
          {:ok, Mogrify.Image.t()} | {:error, String.t()}
  def load_image({:ok, _image} = ok), do: ok
  def load_image({:error, _reason} = error), do: error

  def load_image(path) when is_binary(path) do
    with :ok <- validate_source(path) do
      {:ok, Mogrify.open(path)}
    end
  rescue
    e in File.Error -> {:error, "Cannot open #{Path.basename(path)}: #{Exception.message(e)}"}
    e in ErlangError -> {:error, backend_error(e)}
  end

  @doc """
  Reads metadata for an image straight from ImageMagick plus the filesystem.

  Returns format, pixel dimensions, bit depth, colour space, orientation,
  transparency, byte size, modification time and a megapixel count.
  """
  @spec info(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def info(path) when is_binary(path) do
    with :ok <- validate_source(path),
         {:ok, raw} <- identify(path, format: @identify_fields) do
      parse_info(raw, path)
    end
  end

  @doc """
  True when the image carries an alpha channel, which decides whether a
  thumbnail can be written as JPEG or has to stay PNG.
  """
  @spec has_alpha?(Path.t()) :: boolean()
  def has_alpha?(path) when is_binary(path) do
    case identify(path, format: "'%[opaque]'") do
      {:ok, "false"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # rotate/2, invert/1, convert_to_jpg/2
  # ---------------------------------------------------------------------------

  @doc """
  Rotates an image clockwise by a multiple of 90 degrees.

  Rotating by 0 is a no-op, so the pipeline can call this unconditionally.
  """
  @spec rotate(Mogrify.Image.t(), integer()) :: {:ok, Mogrify.Image.t()} | {:error, String.t()}
  def rotate(image, degrees) when degrees in @rotations and degrees != 0,
    do: {:ok, Mogrify.custom(image, "rotate", degrees)}

  def rotate(image, 0), do: {:ok, image}

  def rotate(_image, degrees),
    do: {:error, "Unsupported rotation: #{inspect(degrees)}°. Use 90, 180 or 270."}

  @doc """
  Inverts the colours of an image (photographic negative).
  """
  @spec invert(Mogrify.Image.t()) :: {:ok, Mogrify.Image.t()}
  def invert(image), do: {:ok, Mogrify.custom(image, "negate")}

  @doc """
  Prepares an image for JPEG output.

  JPEG has no alpha channel, so transparency is flattened onto white first -
  otherwise ImageMagick would composite it onto black.
  """
  @spec convert_to_jpg(Mogrify.Image.t(), keyword()) ::
          {:ok, Mogrify.Image.t()} | {:error, String.t()}
  def convert_to_jpg(image, opts \\ []) do
    quality = Keyword.get(opts, :quality, 75)

    case validate_quality(quality) do
      :ok ->
        prepared =
          image
          |> Mogrify.custom("background", "white")
          |> Mogrify.custom("alpha", "remove")
          |> Mogrify.custom("alpha", "off")
          |> Mogrify.format("jpg")
          |> Mogrify.quality(quality)

        {:ok, prepared}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Prepares an image for WebP output.

  WebP supports an alpha channel, so transparency is kept as-is.
  """
  @spec convert_to_webp(Mogrify.Image.t(), keyword()) ::
          {:ok, Mogrify.Image.t()} | {:error, String.t()}
  def convert_to_webp(image, opts \\ []) do
    quality = Keyword.get(opts, :quality, 75)

    case validate_quality(quality) do
      :ok ->
        prepared = image |> Mogrify.format("webp") |> Mogrify.quality(quality)
        {:ok, prepared}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Prepares an image for PNG output.

  PNG is lossless, so no quality factor is applied; alpha is preserved.
  """
  @spec convert_to_png(Mogrify.Image.t(), keyword()) :: {:ok, Mogrify.Image.t()}
  def convert_to_png(image, _opts \\ []) do
    {:ok, image |> Mogrify.format("png")}
  end

  @doc """
  Validates a JPEG/WebP quality factor against the configured range.
  """
  @spec validate_quality(integer() | atom()) :: :ok | {:error, String.t()}
  def validate_quality(level) when is_atom(level), do: validate_quality(Operations.quality(level))

  def validate_quality(quality) when is_integer(quality) do
    range = Application.get_env(:image_manipulator, :jpg_quality_range, 5..100)

    if quality in range do
      :ok
    else
      {:error, "Image quality must be between #{range.first} and #{range.last}, got #{quality}."}
    end
  end

  def validate_quality(other), do: {:error, "Invalid image quality: #{inspect(other)}."}

  # ---------------------------------------------------------------------------
  # save_image/2
  # ---------------------------------------------------------------------------

  @doc """
  Writes the (possibly transformed) image to disk.

  ## Options

    * `:path`      - required destination
    * `:overwrite` - when false, an existing file is reported as an error
                     instead of being replaced (defaults to true)
  """
  @spec save_image(Mogrify.Image.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def save_image(image, opts) do
    path = Keyword.fetch!(opts, :path)
    overwrite = Keyword.get(opts, :overwrite, true)

    try do
      cond do
        File.dir?(path) ->
          {:error, "#{path} is a directory."}

        File.exists?(path) and not overwrite ->
          {:error, "#{Path.basename(path)} already exists in #{Path.dirname(path)}."}

        true ->
          do_save(image, path)
      end
    rescue
      e in File.Error ->
        {:error, "Could not write #{Path.basename(path)}: #{Exception.message(e)}"}

      e in MatchError ->
        {:error, error_from_match(e, path)}

      e in ErlangError ->
        {:error, backend_error(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Runs a full `ImageManipulator.Operations` pipeline and reports the result.

  ## Options

    * `:target`    - required destination path
    * `:overwrite` - passed through to `save_image/2`
    * `:info`      - extra keys merged into the result's `info` map (the LiveView
                     uses this to keep the source size for a before/after delta)
  """
  @spec process(Path.t(), Operations.t(), keyword()) :: {:ok, Result.t()} | {:error, String.t()}
  def process(source, %Operations{} = operations, opts \\ []) do
    target = Keyword.fetch!(opts, :target)
    overwrite = Keyword.get(opts, :overwrite, true)
    started = System.monotonic_time(:millisecond)

    with {:ok, image} <- load_image(source),
         {:ok, image} <- rotate(image, operations.rotation),
         {:ok, image} <- maybe_invert(image, operations.invert),
         {:ok, image} <- maybe_convert(image, operations),
         {:ok, saved} <- save_image(image, path: target, overwrite: overwrite),
         {:ok, info} <- info(saved.path) do
      {:ok,
       %Result{
         path: saved.path,
         source: source,
         format: info.format,
         width: info.width,
         height: info.height,
         bytes: saved.bytes,
         quality: if(operations.format in [:jpg, :webp], do: Operations.jpg_quality(operations)),
         operations: Operations.summary(operations),
         elapsed_ms: System.monotonic_time(:millisecond) - started,
         info: Map.merge(info, Map.new(Keyword.get(opts, :info, [])))
       }}
    end
  end

  @doc """
  Renders a scaled-down copy of `src` at `dest`, keeping transparency when the
  destination is a PNG. Used for the browser thumbnails and filmstrip.
  """
  @spec thumbnail(Path.t(), Path.t(), integer()) :: {:ok, map()} | {:error, String.t()}
  def thumbnail(src, dest, width) do
    with {:ok, width} <- validate_thumbnail_width(width),
         {:ok, image} <- load_image(src) do
      image =
        image |> Mogrify.custom("thumbnail", "#{width}x#{width}>") |> Mogrify.custom("strip")

      image =
        if png_destination?(dest) do
          image
        else
          image |> Mogrify.custom("background", "white") |> Mogrify.quality(@thumbnail_quality)
        end

      save_image(image, path: dest)
    end
  end

  @doc """
  Bounds check for requested thumbnail sizes.
  """
  @spec validate_thumbnail_width(integer()) :: {:ok, integer()} | {:error, String.t()}
  def validate_thumbnail_width(width) when is_integer(width) and width > 0 do
    if width <= @max_thumbnail_px do
      {:ok, width}
    else
      {:error, "Thumbnails are capped at #{@max_thumbnail_px}px."}
    end
  end

  def validate_thumbnail_width(_width), do: {:error, "Thumbnail size must be a whole number."}

  @doc """
  Extension a cached thumbnail for `src` should use (JPEG for photos,
  PNG when the source carries transparency).
  """
  @spec thumbnail_extension(Path.t()) :: String.t()
  def thumbnail_extension(src) do
    if String.downcase(Path.extname(src)) in [".png", ".gif", ".webp"] and has_alpha?(src) do
      ".png"
    else
      if String.downcase(Path.extname(src)) == ".png", do: ".png", else: ".jpg"
    end
  rescue
    _ -> ".jpg"
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp do_save(image, path) do
    saved = Mogrify.save(image, path: path)

    case File.stat(saved.path) do
      {:ok, stat} ->
        {:ok, %{path: saved.path, bytes: stat.size, format: saved.format, mtime: stat.mtime}}

      {:error, reason} ->
        {:error, "Saved file cannot be read back: #{inspect(reason)}"}
    end
  end

  defp maybe_invert(image, true), do: invert(image)
  defp maybe_invert(image, _false), do: {:ok, image}

  defp maybe_convert(image, %Operations{format: :jpg} = operations),
    do: convert_to_jpg(image, quality: Operations.jpg_quality(operations))

  defp maybe_convert(image, %Operations{format: :webp} = operations),
    do: convert_to_webp(image, quality: Operations.jpg_quality(operations))

  defp maybe_convert(image, %Operations{format: :png}), do: convert_to_png(image)

  defp png_destination?(dest), do: String.downcase(Path.extname(dest)) == ".png"

  @doc """
  Reports why a path cannot be used as an image source, or `:ok`.

  Public so the UI can pre-validate a selection before spawning a task.
  """
  @spec validate_source(Path.t()) :: :ok | {:error, String.t()}
  def validate_source(path) do
    cond do
      not File.exists?(path) -> {:error, "#{Path.basename(path)} no longer exists on disk."}
      File.dir?(path) -> {:error, "#{Path.basename(path)} is a directory, not an image."}
      not File.regular?(path) -> {:error, "#{Path.basename(path)} is not a regular file."}
      not supported_extension?(path) -> {:error, "#{Path.extname(path)} files are not supported."}
      true -> :ok
    end
  end

  defp supported_extension?(path),
    do: String.downcase(Path.extname(path)) in @image_extensions

  defp identify(path, opts) do
    {:ok, path |> Mogrify.identify(opts) |> String.trim()}
  rescue
    e in MatchError -> {:error, error_from_match(e, path)}
    e in ErlangError -> {:error, backend_error(e)}
  end

  defp parse_info(raw, path) do
    case String.split(raw, "|", trim: true) do
      [format, width, height, depth, colorspace, orientation, opaque, bytes, channels] ->
        {:ok,
         build_info(
           path,
           format,
           width,
           height,
           depth,
           colorspace,
           orientation,
           opaque,
           bytes,
           channels
         )}

      _other ->
        {:error, "ImageMagick returned unreadable metadata for #{Path.basename(path)}."}
    end
  end

  defp build_info(
         path,
         format,
         width,
         height,
         depth,
         colorspace,
         orientation,
         opaque,
         bytes,
         channels
       ) do
    %{
      name: Path.basename(path),
      path: path,
      format: String.downcase(format),
      format_label: format_label(format),
      width: to_int(width),
      height: to_int(height),
      depth: to_int(depth),
      colorspace: String.upcase(colorspace),
      orientation: normalize_orientation(orientation),
      has_alpha?: opaque == "false",
      channels: channels,
      bytes: to_int(bytes),
      megapixels: megapixels(width, height),
      mtime: mtime(path)
    }
  end

  defp megapixels(width, height) do
    w = to_int(width)
    h = to_int(height)
    if is_integer(w) and is_integer(h), do: Float.round(w * h / 1_000_000, 1), else: nil
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _reason} -> nil
    end
  end

  defp to_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp normalize_orientation(orientation) do
    case String.downcase(orientation) do
      "undefined" -> "Undefined"
      other -> other |> String.split("-") |> Enum.map_join("-", &String.capitalize/1)
    end
  end

  @doc """
  Display name for an ImageMagick format code, e.g. `"jpeg" -> "JPEG"`.
  """
  @spec format_label(String.t()) :: String.t()
  def format_label(format) do
    case String.downcase(format) do
      "jpeg" -> "JPEG"
      "jpg" -> "JPEG"
      "png" -> "PNG"
      "webp" -> "WebP"
      "gif" -> "GIF"
      "bmp" -> "BMP"
      "tiff" -> "TIFF"
      "tif" -> "TIFF"
      "avif" -> "AVIF"
      other -> String.upcase(other)
    end
  end

  defp parse_formats(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s+([A-Z0-9]+)\*?\s+(\S+)\s+([rw+\-]+)\s/, line) do
        [_all, name, _mode, mode] ->
          if String.contains?(mode, "w") and
               String.downcase(name) in @image_extensions do
            [name]
          else
            []
          end

        _other ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp error_from_match(%MatchError{term: {output, code}}, path) when is_integer(code) do
    detail =
      output
      |> to_string()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    "ImageMagick failed (#{code}) while processing #{Path.basename(path)}: #{detail || "unknown error"}"
  end

  defp error_from_match(%MatchError{}, path),
    do: "ImageMagick could not process #{Path.basename(path)}."

  defp backend_error(%ErlangError{original: :enoent}),
    do: "ImageMagick is not installed or not on PATH. Install it to process images."

  defp backend_error(%ErlangError{original: original}),
    do: "Image processing backend error: #{inspect(original)}"

  defp convert_path, do: System.find_executable("convert")
  defp identify_path, do: System.find_executable("identify")

  defp version_of_mogrify do
    case Application.spec(:mogrify, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
