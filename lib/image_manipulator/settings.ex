defmodule ImageManipulator.Settings do
  @moduledoc """
  User preferences, persisted as JSON under `priv/settings.json`.

  Settings are intentionally small and *effective*: they drive the JPEG quality
  used when converting, the size of the thumbnails requested from the media
  endpoint, the default save destination, and whether existing files may be
  overwritten.

  Anything coming from the browser is treated as untrusted: `parse/1` coerces
  values and `validate/1` re-checks them against the configured guard rails
  before a single byte is written to disk.
  """

  alias ImageManipulator.Paths

  @enforce_keys [:output_dir, :jpg_quality, :thumbnail_size, :overwrite]
  defstruct output_dir: nil, jpg_quality: 75, thumbnail_size: 168, overwrite: true

  @type t :: %__MODULE__{
          output_dir: String.t(),
          jpg_quality: pos_integer(),
          thumbnail_size: pos_integer(),
          overwrite: boolean()
        }

  @fields %{
    output_dir: "outputDir",
    jpg_quality: "jpgQuality",
    thumbnail_size: "thumbnailSize",
    overwrite: "overwrite"
  }

  @doc """
  Built-in defaults, with `:output_dir` pointing at the configured exports dir.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      output_dir: Paths.exports(),
      jpg_quality: 75,
      thumbnail_size: 168,
      overwrite: true
    }
  end

  @doc """
  Reads the settings file and merges it over the defaults.

  A missing or unreadable file is not an error - the defaults are returned so
  the UI always has something to show.
  """
  @spec load() :: t()
  def load do
    case File.read(Paths.settings_file()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, decoded} when is_map(decoded) ->
            decoded |> map_to_struct() |> validate_struct()

          {:error, _reason} ->
            default()
        end

      {:error, _reason} ->
        default()
    end
  end

  @doc """
  The destination directory "Save Image" uses when the user has not picked one.
  """
  @spec output_dir() :: String.t()
  def output_dir do
    case load() do
      %__MODULE__{output_dir: dir} when is_binary(dir) and dir != "" -> dir
      _ -> Paths.exports()
    end
  end

  @doc """
  Turns form params (all strings) into a settings struct.

  Returns `{:error, message}` for values that cannot be coerced at all; range
  and filesystem checks happen in `validate/1`.
  """
  @spec parse(map() | t()) :: {:ok, t()} | {:error, String.t()}
  def parse(%__MODULE__{} = settings), do: {:ok, settings}

  def parse(params) when is_map(params) do
    with {:ok, quality} <- to_int(params["jpg_quality"] || params[:jpg_quality], "JPEG quality"),
         {:ok, thumb} <-
           to_int(params["thumbnail_size"] || params[:thumbnail_size], "Thumbnail size") do
      {:ok,
       %__MODULE__{
         output_dir: params["output_dir"] || params[:output_dir] || Paths.exports(),
         jpg_quality: quality,
         thumbnail_size: thumb,
         overwrite: truthy?(params["overwrite"] || params[:overwrite])
       }}
    end
  end

  @doc """
  Validates every field, including a real write probe against the output
  directory. Never raises.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = settings) do
    quality_range = Application.get_env(:image_manipulator, :jpg_quality_range, 5..100)
    thumb_range = Application.get_env(:image_manipulator, :thumbnail_size_range, 48..512)

    dir = Path.expand(to_string(settings.output_dir), Paths.project_root())

    cond do
      settings.output_dir in [nil, ""] ->
        {:error, "Choose an output directory."}

      settings.jpg_quality not in quality_range ->
        {:error, "JPEG quality must be between #{quality_range.first} and #{quality_range.last}."}

      settings.thumbnail_size not in thumb_range ->
        {:error,
         "Thumbnail size must be between #{thumb_range.first} and #{thumb_range.last} pixels."}

      not writable_directory?(dir) ->
        {:error, "Cannot write to #{dir}. Check that the path exists and is writable."}

      true ->
        {:ok, %{settings | output_dir: dir}}
    end
  end

  @doc false
  def validate_struct(%__MODULE__{} = settings) do
    case validate(settings) do
      {:ok, valid} -> valid
      {:error, _reason} -> default()
    end
  end

  @doc """
  Validates and persists settings. Returns `{:ok, settings}` with the expanded
  output directory, or `{:error, message}` which is safe to show in the UI.
  """
  @spec save(t()) :: {:ok, t()} | {:error, String.t()}
  def save(%__MODULE__{} = settings) do
    with {:ok, valid} <- validate(settings) do
      path = Paths.settings_file()
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"

      payload =
        @fields
        |> Map.new(fn {field, json_key} -> {json_key, Map.fetch!(valid, field)} end)
        |> Jason.encode!(pretty: true)

      case File.write(tmp, payload) do
        :ok ->
          File.rename!(tmp, path)
          {:ok, valid}

        {:error, reason} ->
          File.rm(tmp)
          {:error, "Could not write settings: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  Convenience for form submissions: parse then save.
  """
  @spec save_params(map()) :: {:ok, t()} | {:error, String.t()}
  def save_params(params) do
    with {:ok, parsed} <- parse(params) do
      save(parsed)
    end
  end

  @doc """
  Deletes the persisted file and returns the defaults.
  """
  @spec reset() :: t()
  def reset do
    File.rm(Paths.settings_file())
    default()
  end

  @doc """
  True when the settings file exists on disk.
  """
  @spec persisted?() :: boolean()
  def persisted?, do: File.regular?(Paths.settings_file())

  @doc """
  Checks whether a directory exists (or can be created) and accepts writes.

  Creates the directory if needed, then writes and removes a probe file so the
  answer reflects reality rather than `File.stat/1` alone.
  """
  @spec writable_directory?(Path.t()) :: boolean()
  def writable_directory?(dir) do
    probe = Path.join(dir, ".image_manipulator-write-test")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(probe, "") do
      File.rm(probe)
      true
    else
      _ -> false
    end
  end

  @doc """
  Encodes settings for template rendering.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = settings) do
    %{
      "output_dir" => settings.output_dir,
      "jpg_quality" => settings.jpg_quality,
      "thumbnail_size" => settings.thumbnail_size,
      "overwrite" => settings.overwrite
    }
  end

  defp map_to_struct(decoded) do
    defaults = default()

    %__MODULE__{
      output_dir: decoded["outputDir"] || defaults.output_dir,
      jpg_quality: decoded["jpgQuality"] || defaults.jpg_quality,
      thumbnail_size: decoded["thumbnailSize"] || defaults.thumbnail_size,
      overwrite: Map.get(decoded, "overwrite", defaults.overwrite) == true
    }
  end

  defp to_int(value, _label) when is_integer(value), do: {:ok, value}

  defp to_int(value, label) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "#{label} must be a whole number."}
    end
  end

  defp to_int(nil, label), do: {:error, "#{label} is required."}
  defp to_int(_other, label), do: {:error, "#{label} must be a whole number."}

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
end
