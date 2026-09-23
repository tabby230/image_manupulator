defmodule ImageManipulator.Fmt do
  @moduledoc """
  Small formatting helpers shared by the domain modules and the LiveView.

  Keeping them here (instead of in the web layer) means the same wording appears
  in flash messages, log lines and templates.
  """

  @doc """
  Human readable byte size, e.g. `1_310_720 -> "1.25 MB"`.
  """
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "unknown"

  def bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes < 1_000 -> "#{bytes} B"
      bytes < 1_000_000 -> "#{trim(bytes / 1_000)} KB"
      bytes < 1_000_000_000 -> "#{trim(bytes / 1_000_000)} MB"
      true -> "#{trim(bytes / 1_000_000_000)} GB"
    end
  end

  @doc """
  Pixel dimensions, e.g. `"1920 × 1080"`.
  """
  @spec dimensions(integer() | nil, integer() | nil) :: String.t()
  def dimensions(width, height) when is_integer(width) and is_integer(height),
    do: "#{width} × #{height}"

  def dimensions(_width, _height), do: "unknown"

  @doc """
  Signed percentage, e.g. `-63.4 -> "-63.4%"`.
  """
  @spec percent(float() | integer() | nil) :: String.t()
  def percent(nil), do: "n/a"

  def percent(value) when is_number(value) do
    sign = if value > 0, do: "+", else: ""
    "#{sign}#{trim(value)}%"
  end

  @doc """
  Formats a `DateTime` (or `nil`) as `"12 Aug 2026, 14:03"`.
  """
  @spec datetime(DateTime.t() | nil) :: String.t()
  def datetime(nil), do: "unknown"
  def datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%d %b %Y, %H:%M")

  @doc """
  Relative age such as `"just now"`, `"12 minutes ago"` or `"3 days ago"`.
  """
  @spec ago(DateTime.t() | nil) :: String.t()
  def ago(nil), do: "unknown"

  def ago(%DateTime{} = datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 45 -> "just now"
      seconds < 3_600 -> plural(div(seconds, 60), "minute")
      seconds < 86_400 -> plural(div(seconds, 3_600), "hour")
      seconds < 2_592_000 -> plural(div(seconds, 86_400), "day")
      true -> plural(div(seconds, 2_592_000), "month")
    end
  end

  @doc """
  Turns a POSIX file error into a sentence.
  """
  @spec file_error(atom()) :: String.t()
  def file_error(reason), do: to_string(:file.format_error(reason))

  @doc """
  Collapses a path so it fits in a panel: `"…/Architecture/atrium.jpg"`.
  """
  @spec shorten_path(Path.t(), pos_integer()) :: String.t()
  def shorten_path(path, max \\ 42) when is_binary(path) do
    if String.length(path) <= max do
      path
    else
      "…" <> String.slice(path, -max, max)
    end
  end

  @doc """
  Trims trailing zeros from a float for display.
  """
  @spec trim(float() | integer()) :: String.t()
  def trim(number) when is_integer(number), do: Integer.to_string(number)

  def trim(number) when is_float(number) do
    number
    |> :erlang.float_to_binary(decimals: 2)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp plural(1, unit), do: "1 #{unit} ago"
  defp plural(value, unit), do: "#{value} #{unit}s ago"
end
