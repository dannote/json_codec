defmodule JSONCodec.JSON do
  @moduledoc false

  # Parses with Elixir's JSON module on Elixir 1.18+, or Jason on earlier
  # versions, chosen once when JSONCodec compiles. Errors are normalized to a
  # message so callers see one shape whichever parser is used.

  cond do
    Code.ensure_loaded?(JSON) ->
      @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
      def decode(binary) do
        case JSON.decode(binary) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, message(reason)}
        end
      end

      defp message({:unexpected_end, offset}),
        do: "unexpected end of JSON at byte #{offset}"

      defp message({:invalid_byte, offset, byte}),
        do: "invalid byte #{inspect(<<byte>>)} at byte #{offset}"

      defp message({:unexpected_sequence, offset, bytes}),
        do: "unexpected sequence #{inspect(bytes)} at byte #{offset}"

    Code.ensure_loaded?(Jason) ->
      @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
      def decode(binary) do
        case Jason.decode(binary) do
          {:ok, value} -> {:ok, value}
          {:error, error} -> {:error, Exception.message(error)}
        end
      end

    true ->
      IO.warn(
        "JSONCodec needs Elixir 1.18+ or the :jason dependency to parse JSON",
        Macro.Env.stacktrace(__ENV__)
      )
  end
end
