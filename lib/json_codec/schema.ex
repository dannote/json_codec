defmodule JSONCodec.Schema do
  @moduledoc false

  def object(module) do
    fields = module.__json_codec_fields__()

    properties =
      Map.new(fields, fn field ->
        {field.json, type_schema(field.type)}
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

  def type_schema(:string), do: %{"type" => "string"}
  def type_schema(:integer), do: %{"type" => "integer"}
  def type_schema(:non_neg_integer), do: %{"type" => "integer", "minimum" => 0}
  def type_schema(:pos_integer), do: %{"type" => "integer", "minimum" => 1}
  def type_schema(:float), do: %{"type" => "number"}
  def type_schema(:number), do: %{"type" => "number"}
  def type_schema(:boolean), do: %{"type" => "boolean"}
  def type_schema(:atom), do: %{"type" => "string"}
  def type_schema(:any), do: %{}
  def type_schema(:term), do: %{}
  def type_schema({:nullable, type}), do: Map.put(type_schema(type), "nullable", true)
  def type_schema({:literal, value}), do: %{"const" => value}

  def type_schema({:enum, values}),
    do: %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}

  def type_schema({:list, type}), do: %{"type" => "array", "items" => type_schema(type)}

  def type_schema({:map, :string, value_type}) do
    %{"type" => "object", "additionalProperties" => type_schema(value_type)}
  end

  def type_schema(module) when is_atom(module) do
    if function_exported?(module, :json_schema, 0) do
      module.json_schema()
    else
      %{}
    end
  end
end
