defmodule ImageManipulator.ImageProcessor.Result do
  @moduledoc """
  Outcome of running an `ImageManipulator.Operations` pipeline over a source
  image: where the bytes landed, what they contain and how long it took.
  """

  @enforce_keys [:path, :format, :width, :height, :bytes, :operations, :elapsed_ms]
  defstruct path: nil,
            source: nil,
            format: nil,
            width: nil,
            height: nil,
            bytes: nil,
            quality: nil,
            operations: [],
            elapsed_ms: 0,
            info: %{}

  @type t :: %__MODULE__{
          path: String.t(),
          source: String.t() | nil,
          format: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          bytes: non_neg_integer(),
          quality: integer() | nil,
          operations: [String.t()],
          elapsed_ms: non_neg_integer(),
          info: map()
        }

  @doc """
  Name of the generated file.
  """
  @spec filename(t()) :: String.t()
  def filename(%__MODULE__{path: path}), do: Path.basename(path)

  @doc """
  How much smaller (positive) or larger (negative) the result is compared to the
  source size, as a percentage. Returns `nil` when the source size is unknown.
  """
  @spec size_delta(t()) :: float() | nil
  def size_delta(%__MODULE__{bytes: bytes, info: %{source_bytes: source_bytes}})
      when is_integer(source_bytes) and source_bytes > 0 do
    Float.round((bytes - source_bytes) / source_bytes * 100, 1)
  end

  def size_delta(_result), do: nil
end
