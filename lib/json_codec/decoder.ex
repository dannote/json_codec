defmodule JSONCodec.Decoder do
  @moduledoc false

  alias JSONCodec.Error

  @missing :__json_codec_missing__

  def missing, do: @missing

  def fetch_field(map, atom_key, json_key) when is_map(map) do
    cond do
      Map.has_key?(map, json_key) -> Map.fetch!(map, json_key)
      Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      true -> @missing
    end
  end

  def required!(@missing, path, expected) do
    raise Error, path: path, expected: expected, got: @missing, reason: :missing_required_field
  end

  def required!(value, _path, _expected), do: value

  def default(@missing, fun) when is_function(fun, 0), do: fun.()
  def default(@missing, value), do: value
  def default(value, _default), do: value

  def decode(value, :any, _path, _opts), do: value
  def decode(value, :term, _path, _opts), do: value

  def decode(value, :string, _path, _opts) when is_binary(value), do: value
  def decode(value, :string, path, _opts), do: type_error!(path, :string, value)

  def decode(value, :integer, _path, _opts) when is_integer(value), do: value
  def decode(value, :integer, path, _opts), do: type_error!(path, :integer, value)

  def decode(value, :non_neg_integer, _path, _opts) when is_integer(value) and value >= 0,
    do: value

  def decode(value, :non_neg_integer, path, _opts), do: type_error!(path, :non_neg_integer, value)

  def decode(value, :pos_integer, _path, _opts) when is_integer(value) and value > 0, do: value
  def decode(value, :pos_integer, path, _opts), do: type_error!(path, :pos_integer, value)

  def decode(value, :float, _path, _opts) when is_float(value), do: value
  def decode(value, :float, path, _opts), do: type_error!(path, :float, value)

  def decode(value, :number, _path, _opts) when is_number(value), do: value
  def decode(value, :number, path, _opts), do: type_error!(path, :number, value)

  def decode(value, :boolean, _path, _opts) when is_boolean(value), do: value
  def decode(value, :boolean, path, _opts), do: type_error!(path, :boolean, value)

  def decode(nil, {:nullable, _type}, _path, _opts), do: nil
  def decode(value, {:nullable, type}, path, opts), do: decode(value, type, path, opts)

  def decode(value, {:literal, literal}, _path, _opts) when value == literal, do: value

  def decode(value, {:literal, literal}, path, _opts),
    do: type_error!(path, {:literal, literal}, value)

  def decode(value, {:enum, values}, path, _opts) do
    cond do
      value in values -> value
      is_binary(value) -> decode_atom_enum(value, values, path)
      true -> type_error!(path, {:enum, values}, value)
    end
  end

  def decode(value, :atom, _path, _opts) when is_atom(value), do: value

  def decode(value, :atom, path, opts) when is_binary(value) do
    case Keyword.get(opts, :atom, :existing) do
      :unsafe -> String.to_atom(value)
      :existing -> String.to_existing_atom(value)
      {:enum, values} -> decode_atom_enum(value, values, path)
    end
  rescue
    ArgumentError -> type_error!(path, :existing_atom, value)
  end

  def decode(value, :atom, path, _opts), do: type_error!(path, :atom, value)

  def decode(values, {:list, type}, path, opts) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> decode(value, type, path ++ [index], opts) end)
  end

  def decode(value, {:list, type}, path, _opts), do: type_error!(path, {:list, type}, value)

  def decode(value, {:map, key_type, value_type}, path, opts) when is_map(value) do
    Map.new(value, fn {key, item} ->
      decoded_key = decode_key(key, key_type, path, opts)
      {decoded_key, decode(item, value_type, path ++ [decoded_key], opts)}
    end)
  end

  def decode(value, {:map, key_type, value_type}, path, _opts) do
    type_error!(path, {:map, key_type, value_type}, value)
  end

  def decode(value, module, _path, _opts) when is_map(value) and is_atom(module) do
    if function_exported?(module, :from_map!, 1) do
      module.from_map!(value)
    else
      value
    end
  end

  def decode(value, expected, path, _opts), do: type_error!(path, expected, value)

  def type_error!(path, expected, value) do
    raise Error, path: path, expected: expected, got: value, reason: :invalid_type
  end

  defp decode_key(key, :string, _path, _opts) when is_binary(key), do: key
  defp decode_key(key, :atom, path, opts), do: decode(key, :atom, path, opts)
  defp decode_key(key, type, path, opts), do: decode(key, type, path, opts)

  defp decode_atom_enum(value, values, path) do
    atom = String.to_existing_atom(value)

    if atom in values do
      atom
    else
      type_error!(path, {:enum, values}, value)
    end
  rescue
    ArgumentError -> type_error!(path, {:enum, values}, value)
  end
end
