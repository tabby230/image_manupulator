defmodule ImageManipulator.ImageLibrary do
  @moduledoc """
  Read-only view of the image folders the app is allowed to browse.

  Folders come from `ImageManipulator.Paths`, plus a per-session uploads folder.
  Everything is resolved on the server: the browser sends an opaque folder id
  and file name, and this module maps them back to real paths, so a crafted
  request can never escape the configured roots.
  """

  alias ImageManipulator.{ImageProcessor, Paths}

  @type folder :: %{id: String.t(), label: String.t(), path: String.t(), kind: atom()}
  @type image :: %{
          id: String.t(),
          name: String.t(),
          path: String.t(),
          ext: String.t(),
          bytes: non_neg_integer(),
          mtime: DateTime.t() | nil,
          format_label: String.t()
        }

  @sort_orders [:name, :size, :modified]

  @doc """
  Every folder the user may pick: configured roots, their direct
  sub-directories and the session's upload folder.
  """
  @spec folders(map()) :: [folder()]
  def folders(session), do: [uploads_folder(session)]

  @doc """
  The uploads folder for a session.
  """
  @spec uploads_folder(map()) :: folder()
  def uploads_folder(%{uploads: uploads, id: sid}) do
    %{id: "session:#{sid}", label: "Uploads (this session)", path: uploads, kind: :uploads}
  end

  @doc """
  Looks a folder up by the id previously handed to the browser.
  """
  @spec find_folder([folder()], String.t()) :: {:ok, folder()} | {:error, String.t()}
  def find_folder(folders, id) do
    case Enum.find(folders, &(&1.id == id)) do
      nil -> {:error, "That folder is no longer available."}
      folder -> {:ok, folder}
    end
  end

  @doc """
  Images directly inside a folder (no recursion; sub-folders are separate
  entries in the folder list).
  """
  @spec list_images(Path.t()) :: [image()]
  def list_images(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&image_file?/1)
        |> Enum.map(&describe/1)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Counts images without touching each file's metadata (cheap enough to run for
  every folder in the sidebar).
  """
  @spec count_images(Path.t()) :: non_neg_integer()
  def count_images(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.count(entries, fn entry -> image_file?(Path.join(dir, entry)) end)

      {:error, _reason} ->
        0
    end
  end

  @doc """
  Looks an image up by the file name sent back by the browser.
  """
  @spec find_image([image()], String.t()) :: {:ok, image()} | {:error, String.t()}
  def find_image(images, id) do
    case Enum.find(images, &(&1.id == id)) do
      nil -> {:error, "#{id} is no longer in this folder."}
      image -> {:ok, image}
    end
  end

  @doc """
  Case-insensitive substring search over file names.
  """
  @spec filter_images([image()], String.t()) :: [image()]
  def filter_images(images, query) do
    query = query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      images
    else
      Enum.filter(images, &String.contains?(String.downcase(&1.name), query))
    end
  end

  @doc """
  Sorts images using the natural default direction for the chosen order.
  """
  @spec sort_images([image()], atom()) :: [image()]
  def sort_images(images, order), do: sort_images(images, order, default_direction(order))

  @doc """
  Sorts images; unknown orders fall back to `:name`.
  """
  @spec sort_images([image()], atom(), atom()) :: [image()]
  def sort_images(images, order, direction) do
    order = if order in @sort_orders, do: order, else: :name
    Enum.sort_by(images, &sort_key(&1, order), sort_direction(direction))
  end

  @doc """
  Available sort orders, for the toolbar.
  """
  @spec sort_orders() :: [atom()]
  def sort_orders, do: @sort_orders

  @doc """
  Library-wide statistics for the dashboard and the sidebar badges.

  The walk is capped by `:stat_scan_limit` so a huge photo library cannot make
  the dashboard hang; `truncated?` reports when the cap was hit.
  """
  @spec stats() :: map()
  def stats do
    limit = Application.get_env(:image_manipulator, :stat_scan_limit, 5000)

    Enum.reduce(Paths.library_roots(), empty_stats(), fn root, acc ->
      acc =
        acc
        |> Map.update!(:roots, &(&1 + 1))
        |> Map.update!(:folders, &(&1 + folder_count(root.path)))

      walk(root.path, limit, acc)
    end)
  end

  @doc """
  Most recently modified images across the library, for the dashboard.
  """
  @spec recent(pos_integer()) :: [image()]
  def recent(limit \\ 6) do
    scan_limit = Application.get_env(:image_manipulator, :stat_scan_limit, 5000)

    Paths.library_roots()
    |> Enum.flat_map(fn root -> all_images(root.path, scan_limit) end)
    |> Enum.sort_by(&sort_key(&1, :modified), :desc)
    |> Enum.take(limit)
  end

  @doc """
  Descriptive metadata for an image, straight from ImageMagick.
  """
  @spec metadata(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def metadata(path), do: ImageProcessor.info(path)

  defp empty_stats do
    %{roots: 0, folders: 0, images: 0, bytes: 0, truncated?: false, formats: %{}}
  end

  defp walk(dir, limit, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reduce(acc, fn path, acc ->
          cond do
            acc.images >= limit ->
              %{acc | truncated?: true}

            File.dir?(path) ->
              walk(path, limit, Map.update!(acc, :folders, &(&1 + 1)))

            image_file?(path) ->
              accumulate_image(path, acc)

            true ->
              acc
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp accumulate_image(path, acc) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        %{
          acc
          | images: acc.images + 1,
            bytes: acc.bytes + size,
            formats: Map.update(acc.formats, format_label(path), 1, &(&1 + 1))
        }

      {:error, _reason} ->
        acc
    end
  end

  defp all_images(dir, limit) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(fn path ->
          cond do
            File.dir?(path) -> all_images(path, limit)
            image_file?(path) -> [describe(path)]
            true -> []
          end
        end)
        |> Enum.take(limit)

      {:error, _reason} ->
        []
    end
  end

  defp folder_count(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.count(entries, fn entry ->
          File.dir?(Path.join(dir, entry)) and not Paths.hidden?(entry)
        end)

      {:error, _reason} ->
        0
    end
  end

  defp describe(path) do
    stat = File.stat!(path)

    %{
      id: Path.basename(path),
      name: Path.basename(path),
      path: path,
      ext: String.downcase(Path.extname(path)),
      bytes: stat.size,
      mtime: stat_to_datetime(stat),
      format_label: format_label(path)
    }
  end

  defp stat_to_datetime(%File.Stat{mtime: {{year, month, day}, {hour, minute, second}}}) do
    case DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second)) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  @doc """
  Whether a file name carries one of the image extensions the app accepts.

  Used to pre-validate uploads on the server and shared with `image_file?/1`,
  so the allow-list from `ImageProcessor.image_extensions/0` is never
  duplicated.
  """
  @spec image_name?(String.t()) :: boolean()
  def image_name?(name) do
    String.downcase(Path.extname(name)) in ImageProcessor.image_extensions()
  end

  defp image_file?(path) do
    File.regular?(path) and image_name?(path)
  end

  defp format_label(path) do
    path |> Path.extname() |> String.trim_leading(".") |> ImageProcessor.format_label()
  end

  defp sort_key(image, :name), do: String.downcase(image.name)
  defp sort_key(image, :size), do: image.bytes
  defp sort_key(image, :modified), do: image.mtime || ~U[1970-01-01 00:00:00Z]

  defp sort_direction(:desc), do: :desc
  defp sort_direction(_other), do: :asc

  @doc false
  def default_direction(:size), do: :desc
  def default_direction(:modified), do: :desc
  def default_direction(_order), do: :asc
end
