defmodule JSONCodec.Schema do
  @moduledoc false

  def object(module), do: object(module, %{}, "#")

  def type_schema(type), do: type_schema(type, %{}, "#")

  defp object(module, seen, path) do
    seen = Map.put(seen, module, path)
    fields = module.__json_codec_fields__()

    properties =
      Map.new(fields, fn field ->
        {field.json,
         type_schema(field.type, seen, path <> "/properties/" <> pointer_token(field.json))}
      end)

    required =
      fields
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.json)

    schema = %{"type" => "object", "properties" => properties, "additionalProperties" => false}

    case required do
      [] -> schema
      _ -> Map.put(schema, "required", required)
    end
  end

  defp type_schema(:string, _seen, _path), do: %{"type" => "string"}
  defp type_schema(:integer, _seen, _path), do: %{"type" => "integer"}
  defp type_schema(:non_neg_integer, _seen, _path), do: %{"type" => "integer", "minimum" => 0}
  defp type_schema(:pos_integer, _seen, _path), do: %{"type" => "integer", "minimum" => 1}
  defp type_schema(:float, _seen, _path), do: %{"type" => "number"}
  defp type_schema(:number, _seen, _path), do: %{"type" => "number"}
  defp type_schema(:boolean, _seen, _path), do: %{"type" => "boolean"}
  defp type_schema(:atom, _seen, _path), do: %{"type" => "string"}
  defp type_schema(:any, _seen, _path), do: %{}
  defp type_schema(:term, _seen, _path), do: %{}

  defp type_schema({:nullable, type}, seen, path),
    do: Map.put(type_schema(type, seen, path), "nullable", true)

  defp type_schema({:literal, value}, _seen, _path), do: %{"const" => value}

  defp type_schema({:enum, values}, _seen, _path),
    do: %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}

  defp type_schema({:list, type}, seen, path),
    do: %{"type" => "array", "items" => type_schema(type, seen, path <> "/items")}

  defp type_schema({:map, :string, value_type}, seen, path) do
    %{
      "type" => "object",
      "additionalProperties" => type_schema(value_type, seen, path <> "/additionalProperties")
    }
  end

  defp type_schema(module, seen, path) when is_atom(module) do
    case Map.fetch(seen, module) do
      {:ok, reference} -> %{"$ref" => reference}
      :error -> module_schema(module, seen, path)
    end
  end

  defp module_schema(module, seen, path) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :__json_codec_fields__, 0) -> object(module, seen, path)
      function_exported?(module, :json_schema, 0) -> module.json_schema()
      true -> %{}
    end
  end

  defp pointer_token(key) do
    key
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
    |> URI.encode(&URI.char_unreserved?/1)
  end
end
