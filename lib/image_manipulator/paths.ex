defmodule ImageManipulator.Paths do
  @moduledoc """
  Resolves every filesystem location the application is allowed to touch.

  All configured paths are stored relative to `:project_root` so that the
  project stays portable. This module expands them once and exposes the small
  set of directories the rest of the app works with:

    * `library_roots/0` - read-only folders that may be browsed
    * `workspace/1`     - per-session scratch space (uploads, previews, outputs)
    * `thumbs/0`        - on-disk cache for generated thumbnails
    * `exports/0`       - fallback destination for "Save Image"

  It also provides `contained?/2` and `writable?/1`, which are used as the
  safety checks whenever a user supplied path is involved.
  """

  @type root :: %{id: String.t(), label: String.t(), path: String.t()}

  @doc """
  Absolute path that relative configuration values are resolved against.
  """
  @spec project_root() :: String.t()
  def project_root do
    Application.get_env(:image_manipulator, :project_root) || File.cwd!()
  end

  @doc """
  Expands a configured path against the project root.
  """
  @spec expand(Path.t()) :: String.t()
  def expand(path), do: Path.expand(path, project_root())

  @doc """
  The browsable library roots, expanded and guaranteed to exist.

  Roots that do not exist on disk are kept in the list (so the UI can tell the
  user about them) but flagged with `:available?`.
  """
  @spec library_roots() :: [root()]
  def library_roots do
    :image_manipulator
    |> Application.get_env(:library_roots, [])
    |> Enum.map(fn root ->
      path = expand(root.path)

      %{
        id: root.id,
        label: root.label,
        path: path,
        available?: File.dir?(path)
      }
    end)
  end

  @doc """
  Walks the configured library roots and returns the folders that may be
  selected in the UI: each root itself plus its direct sub-directories.
  """
  @spec folders() :: [map()]
  def folders do
    Enum.flat_map(library_roots(), fn root ->
      folder = %{id: "root:#{root.id}", label: root.label, path: root.path, kind: :root}

      subfolders =
        case File.ls(root.path) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.map(&Path.join(root.path, &1))
            |> Enum.filter(&(File.dir?(&1) and not hidden?(Path.basename(&1))))
            |> Enum.map(fn path ->
              %{
                id: "root:#{root.id}/#{Path.relative_to(path, root.path)}",
                label: Path.basename(path),
                path: path,
                kind: :subfolder
              }
            end)

          {:error, _reason} ->
            []
        end

      [folder | subfolders]
    end)
  end

  @doc """
  Per-session scratch directories. Nothing is created until `ensure/1` runs.
  """
  @spec workspace(String.t()) :: map()
  def workspace(sid) do
    root =
      Path.join(
        expand(Application.get_env(:image_manipulator, :workspace_dir, "priv/workspace")),
        Path.join("sessions", sid)
      )

    %{
      id: sid,
      root: root,
      uploads: Path.join(root, "uploads"),
      previews: Path.join(root, "previews"),
      outputs: Path.join(root, "outputs")
    }
  end

  @doc """
  Cache directory for generated thumbnails (shared across sessions).
  """
  @spec thumbs() :: String.t()
  def thumbs do
    expand(
      Path.join(
        Application.get_env(:image_manipulator, :workspace_dir, "priv/workspace"),
        "cache/thumbs"
      )
    )
  end

  @doc """
  Root of all session workspaces; used when pruning stale sessions.
  """
  @spec workspace_root() :: String.t()
  def workspace_root do
    expand(Application.get_env(:image_manipulator, :workspace_dir, "priv/workspace"))
  end

  @doc """
  Fallback output directory for saved images.
  """
  @spec exports() :: String.t()
  def exports do
    expand(Application.get_env(:image_manipulator, :default_output_dir, "priv/exports"))
  end

  @doc """
  JSON file holding persisted settings.
  """
  @spec settings_file() :: String.t()
  def settings_file do
    expand(Application.get_env(:image_manipulator, :settings_file, "priv/settings.json"))
  end

  @doc """
  Every directory a user is allowed to read images from.

  Includes `Settings.output_dir/0`: "Save Image" may write to any writable
  directory (the remembered location can be anywhere on disk), and the files it
  produces are shown as thumbnails in the My Images gallery. Their media tokens
  are re-validated on redemption, so without the configured output directory
  here those thumbnails would answer 403 and render as broken images.
  """
  @spec readable_roots() :: [String.t()]
  def readable_roots do
    (Enum.map(library_roots(), & &1.path) ++
       [workspace_root(), exports(), ImageManipulator.Settings.output_dir()])
    |> Enum.uniq()
  end

  @doc """
  Every directory a user is allowed to write generated images into.
  """
  @spec writable_roots() :: [String.t()]
  def writable_roots do
    [workspace_root(), exports(), ImageManipulator.Settings.output_dir()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Returns true when `path` lives inside `root` (after symlink-free expansion).

  Used to keep every request confined to configured directories.
  """
  @spec contained?(Path.t(), Path.t()) :: boolean()
  def contained?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    relative = Path.relative_to(path, root)

    relative == "." or
      (Path.type(relative) == :relative and
         relative != ".." and not String.starts_with?(relative, "../"))
  end

  @doc """
  Returns true when `path` is inside any readable root.
  """
  @spec readable?(Path.t()) :: boolean()
  def readable?(path), do: Enum.any?(readable_roots(), &contained?(path, &1))

  @doc """
  Returns true when `path` is inside any writable root.
  """
  @spec writable?(Path.t()) :: boolean()
  def writable?(path), do: Enum.any?(writable_roots(), &contained?(path, &1))

  @doc false
  def hidden?("." <> _rest), do: true
  def hidden?(_name), do: false
end
