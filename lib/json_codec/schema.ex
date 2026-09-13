defmodule JSONCodec.Schema do
  @moduledoc false

  def object(module), do: type_schema(module)

  def type_schema(type) do
    JSONSpec.from_type(type, resolve: &resolve/1, nullable: :legacy)
  end

  defp resolve(module) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :__json_codec_fields__, 0) ->
        fields =
          Enum.map(module.__json_codec_fields__(), fn field ->
            %{name: field.json, type: field.type, required: field.required}
          end)

        {:object, fields}

      function_exported?(module, :json_schema, 0) ->
        {:schema, module.json_schema()}

      true ->
        {:schema, %{}}
    end
  end
end
