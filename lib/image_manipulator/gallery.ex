defmodule ImageManipulator.Gallery do
  @moduledoc """
  Builds the **real** output gallery for one "Apply Changes" run.

  Every entry this module returns is a file that exists on disk: the untouched
  original is referenced, and each requested pipeline permutation is written
  into the session's outputs directory through
  `ImageManipulator.ImageProcessor`.

  Two shapes are produced:

    * a JPEG sweep - when the pipeline converts to JPEG, the image is written
      three times (High / Medium / Low compression) so the user can compare
      real file sizes; the sweep entry matching the selected compression level
      is flagged as the applied result;
    * a single applied file - for rotation and/or colour inversion, written in
      the source container.

  The module returns plain data (`ImageManipulator.Gallery.Entry`), never URLs;
  the LiveView decorates entries with signed media links.
  """

  alias ImageManipulator.{Fmt, ImageProcessor, Operations, Workspace}
  alias ImageManipulator.Gallery.Entry

  # Compression level -> JPEG quality factor. High compression means a *lower*
  # quality factor, which is why the mapping looks inverted.
  @jpeg_sweep [high: 90, medium: 75, low: 55]

  @sweep_labels %{
    high: "JPG (High Quality)",
    medium: "JPG (Medium Quality)",
    low: "JPG (Low Quality)"
  }

  @doc """
  Compression levels included in the JPEG sweep, strongest first.
  """
  @spec jpeg_sweep() :: [{Operations.compression(), integer()}]
  def jpeg_sweep, do: @jpeg_sweep

  @doc """
  Builds every output for `source` under `operations`.

  ## Options

    * `:target_dir` - required directory the generated files are written to
    * `:overwrite`  - passed through to `ImageProcessor.process/3`

  Returns `{:ok, entries}` (pipeline outputs first, the original last) or
  `{:error, reason}` when the source cannot be processed at all.
  """
  @spec build(Path.t(), map() | nil, Operations.t(), keyword()) ::
          {:ok, [Entry.t()]} | {:error, String.t()}
  def build(source, metadata, %Operations{} = operations, opts) do
    dir = Keyword.fetch!(opts, :target_dir)

    case File.mkdir_p(dir) do
      :ok -> build_entries(source, metadata, operations, dir, opts)
      {:error, reason} -> {:error, "Cannot create #{dir}: #{Fmt.file_error(reason)}"}
    end
  end

  @doc """
  Writes `source` to `destination`, honouring the destination extension.

  A `.jpg`/`.jpeg`, `.webp` or `.png` destination is re-encoded by ImageMagick
  at `:quality` (default `75`) — PNG ignores the quality factor as it is
  lossless. Anything else is copied byte for byte. Existing files are protected
  when `:overwrite` is `false`.
  """
  @spec save_as(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def save_as(source, destination, opts \\ []) do
    overwrite = Keyword.get(opts, :overwrite, true)
    quality = Keyword.get(opts, :quality, 75)

    with :ok <- validate_source(source),
         :ok <- validate_destination(destination, overwrite) do
      case File.mkdir_p(Path.dirname(destination)) do
        :ok -> write_as(source, destination, quality, overwrite)
        {:error, reason} -> {:error, Fmt.file_error(reason)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Entry building
  # ---------------------------------------------------------------------------

  defp build_entries(source, metadata, operations, dir, opts) do
    base = Path.basename(source, Path.extname(source))

    case sweep_or_applied(source, operations, dir, base, opts) do
      {:ok, entries} ->
        case original_entry(source, metadata) do
          {:ok, original} -> {:ok, entries ++ [original]}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Convert to JPEG: always write the whole High/Medium/Low sweep so the effect
  # of the compression level on file size is visible.
  defp sweep_or_applied(source, %Operations{format: :jpg} = operations, dir, base, opts) do
    rotation = operations.rotation
    invert = operations.invert

    Enum.reduce_while(@jpeg_sweep, {:ok, []}, fn {level, quality}, {:ok, acc} ->
      target = Path.join(dir, Workspace.unique_path(dir, "#{base}-jpg-#{level}.jpg"))

      level_ops = %Operations{
        rotation: rotation,
        invert: invert,
        format: :jpg,
        compression: level
      }

      case run(source, level_ops, target, opts) do
        {:ok, entry} ->
          applied? = operations.compression == level
          {:cont, {:ok, acc ++ [%{entry | applied?: applied?, quality: quality}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sweep_or_applied(source, %Operations{} = operations, dir, base, opts) do
    if Operations.pending?(operations) do
      ext = Operations.output_extension(operations) || Path.extname(source)
      target = Path.join(dir, Workspace.unique_path(dir, "#{base}-edited#{ext}"))

      case run(source, operations, target, opts) do
        {:ok, entry} -> {:ok, [%{entry | applied?: true, label: applied_label(operations)}]}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp run(source, operations, target, opts) do
    case ImageProcessor.process(source, operations, Keyword.put(opts, :target, target)) do
      {:ok, result} ->
        {:ok,
         %Entry{
           id: result.path,
           kind: if(operations.format == :jpg, do: :jpeg, else: :applied),
           label: label_for(operations),
           path: result.path,
           bytes: result.bytes,
           width: result.width,
           height: result.height,
           format_label: Map.get(result.info, :format_label) || result.format,
           quality: result.quality,
           operations: result.operations,
           elapsed_ms: result.elapsed_ms,
           applied?: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp original_entry(source, metadata) do
    info =
      case metadata do
        %{width: width, height: height} = info when is_integer(width) and is_integer(height) ->
          {:ok, info}

        _other ->
          ImageProcessor.info(source)
      end

    case info do
      {:ok, info} ->
        {:ok,
         %Entry{
           id: source,
           kind: :original,
           label: "Original",
           path: source,
           bytes: info.bytes,
           width: info.width,
           height: info.height,
           format_label: info.format_label,
           quality: nil,
           operations: [],
           elapsed_ms: 0,
           applied?: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Labels
  # ---------------------------------------------------------------------------

  defp label_for(%Operations{format: :jpg, compression: level}) do
    Map.get(@sweep_labels, level, "JPG")
  end

  defp label_for(%Operations{} = operations), do: applied_label(operations)

  defp applied_label(%Operations{rotation: rotation, invert: invert, format: format}) do
    base =
      cond do
        rotation != 0 and invert -> "Rotated (#{rotation}°) + Inverted"
        rotation != 0 -> "Rotated (#{rotation}°)"
        invert -> "Inverted Colours"
        true -> "Processed"
      end

    if format == :jpg do
      base
    else
      "#{base} · #{format_name(format)}"
    end
  end

  defp format_name(:png), do: "PNG"
  defp format_name(:webp), do: "WebP"

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write_as(source, destination, quality, overwrite) do
    case destination_format(destination) do
      {:ok, :jpg} ->
        convert(source, destination, :jpg, quality, overwrite)

      {:ok, :webp} ->
        convert(source, destination, :webp, quality, overwrite)

      {:ok, :png} ->
        convert(source, destination, :png, nil, overwrite)

      :error ->
        copy(source, destination)
    end
  end

  defp convert(source, destination, format, quality, overwrite) do
    with {:ok, image} <- ImageProcessor.load_image(source),
         {:ok, image} <- convert_to_format(image, format, quality),
         {:ok, saved} <-
           ImageProcessor.save_image(image, path: destination, overwrite: overwrite) do
      {:ok, saved}
    end
  end

  defp convert_to_format(image, :jpg, quality),
    do: ImageProcessor.convert_to_jpg(image, quality: quality)

  defp convert_to_format(image, :webp, quality),
    do: ImageProcessor.convert_to_webp(image, quality: quality)

  defp convert_to_format(image, :png, _quality),
    do: ImageProcessor.convert_to_png(image)

  defp destination_format(path) do
    case String.downcase(Path.extname(path)) do
      ".jpg" -> {:ok, :jpg}
      ".jpeg" -> {:ok, :jpg}
      ".webp" -> {:ok, :webp}
      ".png" -> {:ok, :png}
      _other -> :error
    end
  end

  defp copy(source, destination) do
    case File.cp(source, destination) do
      :ok ->
        case File.stat(destination) do
          {:ok, stat} -> {:ok, %{path: destination, bytes: stat.size}}
          {:error, reason} -> {:error, Fmt.file_error(reason)}
        end

      {:error, reason} ->
        {:error, "Could not write #{Path.basename(destination)}: #{Fmt.file_error(reason)}"}
    end
  end

  defp validate_source(path) do
    if File.regular?(path) do
      :ok
    else
      {:error, "#{Path.basename(path)} is no longer on disk."}
    end
  end

  defp validate_destination(path, overwrite) do
    cond do
      File.dir?(path) ->
        {:error, "#{Path.basename(path)} is a directory."}

      File.exists?(path) and not overwrite ->
        {:error, "Refusing to overwrite #{Path.basename(path)}."}

      Path.basename(path) in ["", "."] ->
        {:error, "Choose a file name."}

      true ->
        :ok
    end
  end
end
