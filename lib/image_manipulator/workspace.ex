defmodule ImageManipulator.Workspace do
  @moduledoc """
  Everything that touches the disk on behalf of one editing session.

  Responsibilities:

    * per-session scratch directories (uploads, previews, outputs) - see
      `ImageManipulator.Paths`
    * housekeeping: stale sessions and oversized thumbnail caches are pruned
      when the studio mounts, so long sessions cannot fill the disk
    * thumbnail generation with an on-disk cache keyed by path, size and mtime
    * storing uploaded files under sanitised names
    * minting and verifying the signed tokens the browser uses to fetch image
      bytes from `/media/:token`, which is how previews avoid shipping base64
      through the LiveView socket
  """

  alias ImageManipulator.{Fmt, ImageProcessor, Paths, Settings}

  # -------------------------------------------------------------------------
  # Session directories
  # -------------------------------------------------------------------------

  @doc """
  Creates a session identifier and its directory layout.
  """
  @spec new_session() :: map()
  def new_session do
    sid = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Paths.workspace(sid) |> ensure()
  end

  @doc """
  Rebuilds the directory layout for an existing session id.
  """
  @spec session(String.t()) :: map()
  def session(sid), do: Paths.workspace(sid)

  @doc """
  Creates the three session directories and returns the session map.
  """
  @spec ensure(map()) :: map()
  def ensure(%{uploads: uploads, previews: previews, outputs: outputs} = session) do
    Enum.each([uploads, previews, outputs], &File.mkdir_p!/1)
    session
  end

  @doc """
  Removes session directories that have not been touched for the configured TTL.
  """
  @spec prune_stale() :: non_neg_integer()
  def prune_stale do
    ttl = Application.get_env(:image_manipulator, :session_ttl_hours, 24) * 3600
    cutoff = System.system_time(:second) - ttl
    sessions_dir = Path.join(Paths.workspace_root(), "sessions")

    case File.ls(sessions_dir) do
      {:ok, entries} ->
        Enum.count(entries, fn entry ->
          path = Path.join(sessions_dir, entry)

          with true <- File.dir?(path),
               {:ok, stat} <- File.stat(path, time: :posix),
               true <- stat.mtime < cutoff do
            File.rm_rf(path)
            true
          else
            _ -> false
          end
        end)

      {:error, _reason} ->
        0
    end
  end

  @doc """
  Number of files and total bytes held by a session.
  """
  @spec usage(map()) :: %{files: non_neg_integer(), bytes: non_neg_integer()}
  def usage(%{root: root}) do
    root
    |> files_under()
    |> Enum.reduce(%{files: 0, bytes: 0}, fn path, acc ->
      size =
        case File.stat(path) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end

      %{acc | files: acc.files + 1, bytes: acc.bytes + size}
    end)
  end

  @doc """
  Lists everything generated for a session (uploads, previews, outputs).
  """
  @spec files(map()) :: [map()]
  def files(%{uploads: uploads, previews: previews, outputs: outputs}) do
    for {dir, kind} <- [{uploads, :upload}, {previews, :preview}, {outputs, :output}],
        path <- files_under(dir) do
      stat = File.stat!(path)
      %{kind: kind, path: path, name: Path.basename(path), bytes: stat.size, mtime: stat.mtime}
    end
  end

  # -------------------------------------------------------------------------
  # Thumbnails
  # -------------------------------------------------------------------------

  @doc """
  Returns a cached thumbnail for `src`, generating it on first use.

  The cache key includes the file's mtime and size, so editing a library image
  invalidates its thumbnail automatically.
  """
  @spec thumbnail(Path.t(), integer()) :: {:ok, Path.t()} | {:error, String.t()}
  def thumbnail(src, width) do
    with :ok <- ImageProcessor.validate_source(src),
         {:ok, width} <- ImageProcessor.validate_thumbnail_width(width) do
      ext = ImageProcessor.thumbnail_extension(src)
      dest = Path.join(Paths.thumbs(), "#{cache_key(src, width)}#{ext}")

      if File.regular?(dest) do
        {:ok, dest}
      else
        File.mkdir_p!(Paths.thumbs())

        case ImageProcessor.thumbnail(src, dest, width) do
          {:ok, %{path: path}} -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  Deletes the oldest cached thumbnails once the cache grows past `limit`.
  """
  @spec prune_thumbs(pos_integer()) :: non_neg_integer()
  def prune_thumbs(limit \\ 2000) do
    dir = Paths.thumbs()

    case File.ls(dir) do
      {:ok, entries} when length(entries) > limit ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort_by(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, stat} -> stat.mtime
            _ -> 0
          end
        end)
        |> Enum.take(length(entries) - limit)
        |> Enum.count(fn path ->
          File.rm(path)
          true
        end)

      _other ->
        0
    end
  end

  # -------------------------------------------------------------------------
  # Uploads
  # -------------------------------------------------------------------------

  @doc """
  Copies a consumed upload entry into the session's uploads directory.

  The stored file is verified to be a readable image before it is accepted, and
  the client supplied name is sanitised - never trusted as a path.
  """
  @spec store_upload(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def store_upload(session, entry) do
    uploads = ensure(session).uploads
    name = unique_path(uploads, sanitise_filename(entry.client_name || "upload"))
    destination = Path.join(uploads, name)

    case File.cp(entry.path, destination) do
      :ok ->
        case ImageProcessor.info(destination) do
          {:ok, info} ->
            {:ok, Map.merge(info, %{path: destination, source: :upload})}

          {:error, reason} ->
            File.rm(destination)
            {:error, "#{name} is not a readable image (#{reason})."}
        end

      {:error, reason} ->
        {:error, "Could not store #{name}: #{Fmt.file_error(reason)}"}
    end
  end

  @doc """
  Removes a file created by the app (upload, preview or output).

  Refuses to touch anything outside the workspace or exports directory.
  """
  @spec remove(Path.t()) :: :ok | {:error, String.t()}
  def remove(path) do
    if Paths.writable?(path) do
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> {:error, Fmt.file_error(reason)}
      end
    else
      {:error, "Refusing to delete #{path}: outside the workspace."}
    end
  end

  # -------------------------------------------------------------------------
  # Output paths
  # -------------------------------------------------------------------------

  @doc """
  Builds a destination inside `dir` for an output image, avoiding collisions.

  `extension` may be `nil`, in which case the source extension is reused.
  """
  @spec output_path(Path.t(), String.t(), String.t() | nil) :: Path.t()
  def output_path(dir, source_name, extension) do
    base = Path.basename(source_name, Path.extname(source_name))
    unique_path(dir, base <> (extension || Path.extname(source_name)))
  end

  @doc """
  Sanitises a user supplied file name: no directories, no traversal, no
  reserved characters, always non-empty.
  """
  @spec sanitise_filename(String.t()) :: String.t()
  def sanitise_filename(name) do
    cleaned =
      name
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._ \-]+/, "-")
      |> String.replace(~r/^[.\-\s]+/, "")
      |> String.trim()
      |> String.slice(0, 120)

    if cleaned in ["", ".", ".."], do: "image", else: cleaned
  end

  @doc """
  Returns `name` unchanged when it is free, otherwise `name-2`, `name-3`, ...
  """
  @spec unique_path(Path.t(), String.t()) :: String.t()
  def unique_path(dir, name) do
    name = sanitise_filename(name)

    if File.exists?(Path.join(dir, name)) do
      ext = Path.extname(name)
      find_free_name(dir, Path.basename(name, ext), ext, 2)
    else
      name
    end
  end

  defp find_free_name(dir, base, ext, index) do
    candidate = "#{base}-#{index}#{ext}"

    if File.exists?(Path.join(dir, candidate)) do
      find_free_name(dir, base, ext, index + 1)
    else
      candidate
    end
  end

  @doc """
  Keeps only the `keep` most recent preview files for a session.
  """
  @spec prune_previews(map(), pos_integer()) :: non_neg_integer()
  def prune_previews(session, keep \\ 4) do
    session.previews
    |> files_under()
    |> Enum.map(fn path ->
      mtime =
        case File.stat(path, time: :posix) do
          {:ok, stat} -> stat.mtime
          _ -> 0
        end

      {path, mtime}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.drop(keep)
    |> Enum.count(fn {path, _mtime} ->
      File.rm(path)
      true
    end)
  end

  # -------------------------------------------------------------------------
  # Media tokens
  # -------------------------------------------------------------------------

  @doc """
  Signs a token that lets the browser fetch `path` from `/media/:token`.

  `:width` requests a thumbnail (re-validated when the token is redeemed) and
  `:download` marks the response as a file download.
  """
  @spec sign_media(Path.t(), keyword()) :: String.t()
  def sign_media(path, opts \\ []) do
    path = Path.expand(path)

    payload = %{
      "p" => path,
      "v" => version(path),
      "w" => Keyword.get(opts, :width),
      "d" => Keyword.get(opts, :download)
    }

    Phoenix.Token.sign(ImageManipulatorWeb.Endpoint, salt(), payload)
  end

  @doc """
  URL that serves a media token.
  """
  @spec media_url(Path.t(), keyword()) :: String.t()
  def media_url(path, opts \\ []), do: "/media/" <> sign_media(path, opts)

  @doc """
  Verifies a media token and describes the request it represents.

  The returned path is guaranteed to sit inside a readable root, so a tampered
  token still cannot read arbitrary files.
  """
  @spec verify_media(String.t()) :: {:ok, map()} | {:error, String.t()}
  def verify_media(token) when is_binary(token) do
    case Phoenix.Token.verify(ImageManipulatorWeb.Endpoint, salt(), token, max_age: :infinity) do
      {:ok, payload} -> authorise(payload)
      {:error, reason} -> {:error, "Invalid media token (#{reason})."}
    end
  end

  defp authorise(%{"p" => path} = payload) do
    if Paths.readable?(path) do
      {:ok, %{path: path, version: payload["v"], download: payload["d"], width: payload["w"]}}
    else
      {:error, "Media outside the configured library."}
    end
  end

  defp authorise(_payload), do: {:error, "Malformed media token."}

  @doc """
  Destination directory used when the user has not overridden it.
  """
  @spec default_output_dir() :: String.t()
  def default_output_dir, do: Settings.output_dir()

  defp salt do
    Application.get_env(:image_manipulator, :media_token_salt, "image-manipulator/media")
  end

  defp version(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> "#{mtime}-#{size}"
      {:error, _reason} -> nil
    end
  end

  defp cache_key(src, width) do
    fingerprint = "#{Path.expand(src)}|#{width}|#{inspect(File.stat(src, time: :posix))}"

    fingerprint
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  # Walks a directory tree and returns every regular file below it.
  defp files_under(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(fn path ->
          cond do
            File.regular?(path) -> [path]
            File.dir?(path) -> files_under(path)
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end
end
