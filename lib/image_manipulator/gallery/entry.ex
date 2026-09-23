defmodule ImageManipulator.Gallery.Entry do
  @moduledoc """
  One file in the output gallery: what was generated, where it lives and the
  statistics shown on its card.

  `:applied?` marks the entry produced by the pipeline the user actually asked
  for, which the Save panel uses as the default save source.
  """

  @enforce_keys [:id, :kind, :label, :path, :bytes, :width, :height, :format_label]
  defstruct id: nil,
            kind: :original,
            label: nil,
            path: nil,
            bytes: 0,
            width: nil,
            height: nil,
            format_label: nil,
            quality: nil,
            operations: [],
            elapsed_ms: 0,
            applied?: false,
            url: nil,
            thumb_url: nil,
            download_url: nil

  @type kind :: :original | :applied | :jpeg

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          path: String.t(),
          bytes: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          format_label: String.t(),
          quality: integer() | nil,
          operations: [String.t()],
          elapsed_ms: non_neg_integer(),
          applied?: boolean(),
          url: String.t() | nil,
          thumb_url: String.t() | nil,
          download_url: String.t() | nil
        }

  @doc """
  True when the entry was produced by the requested pipeline.
  """
  @spec applied?(t()) :: boolean()
  def applied?(%__MODULE__{applied?: applied?}), do: applied? == true

  @doc """
  Extension of the generated file, lower case.
  """
  @spec extension(t()) :: String.t()
  def extension(%__MODULE__{path: path}), do: path |> Path.extname() |> String.downcase()
end
