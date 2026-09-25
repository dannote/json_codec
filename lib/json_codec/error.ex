defmodule JSONCodec.Error do
  defexception [:path, :expected, :got, :reason, :details]

  @type t :: %__MODULE__{
          path: [atom() | String.t() | non_neg_integer()],
          expected: term(),
          got: term(),
          reason: atom(),
          details: term()
        }

  @impl true
  def message(%__MODULE__{
        path: path,
        expected: expected,
        got: got,
        reason: reason,
        details: details
      }) do
    location =
      case path do
        [] -> "$"
        parts -> Enum.map_join(parts, &format_path_part/1)
      end

    "#{location}: #{reason}#{details(details)}, expected #{inspect(expected)}, got #{inspect(got)}"
  end

  defp details(nil), do: ""
  defp details(details), do: " (#{inspect(details)})"

  defp format_path_part(part) when is_integer(part), do: "[#{part}]"
  defp format_path_part(part), do: ".#{part}"
end
