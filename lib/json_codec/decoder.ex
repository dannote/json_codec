defmodule JSONCodec.Decoder do
  @moduledoc false

  alias JSONCodec.Error

  @compile {:inline, default: 2, fetch_field: 3, required!: 3}

  @missing :__json_codec_missing__

  def missing, do: @missing

  def fetch_field(map, atom_key, json_key) when is_map(map) do
    case :maps.get(json_key, map, @missing) do
      @missing -> :maps.get(atom_key, map, @missing)
      value -> value
    end
  end

  def required!(@missing, path, expected) do
    raise Error, path: path, expected: expected, got: nil, reason: :missing_required_field
  end

  def required!(value, _path, _expected), do: value

  def cast!({:ok, value}, _raw, _path, _expected), do: value

  def cast!(:error, raw, path, expected) do
    raise Error, path: path, expected: expected, got: raw, reason: :invalid_value
  end

  def cast!({:error, details}, raw, path, expected) do
    raise Error,
      path: path,
      expected: expected,
      got: raw,
      reason: :invalid_value,
      details: details
  end

  def cast!(other, _raw, path, _expected) do
    raise ArgumentError,
          "cast callback for #{inspect(path)} must return {:ok, value}, :error, or {:error, reason}, got: #{inspect(other)}"
  end

  def default(@missing, fun) when is_function(fun, 0), do: fun.()
  def default(@missing, value), do: value
  def default(value, _default), do: value

  def decode(value, type, path, opts), do: decode(value, type, path, opts, nil)

  def decode(value, :any, _path, _opts, _source), do: value
  def decode(value, :term, _path, _opts, _source), do: value

  def decode(value, :string, _path, _opts, _source) when is_binary(value), do: value
  def decode(value, :string, path, _opts, _source), do: type_error!(path, :string, value)

  def decode(value, :integer, _path, _opts, _source) when is_integer(value), do: value
  def decode(value, :integer, path, _opts, _source), do: type_error!(path, :integer, value)

  def decode(value, :non_neg_integer, _path, _opts, _source)
      when is_integer(value) and value >= 0,
      do: value

  def decode(value, :non_neg_integer, path, _opts, _source),
    do: type_error!(path, :non_neg_integer, value)

  def decode(value, :pos_integer, _path, _opts, _source) when is_integer(value) and value > 0,
    do: value

  def decode(value, :pos_integer, path, _opts, _source),
    do: type_error!(path, :pos_integer, value)

  def decode(value, :float, _path, _opts, _source) when is_float(value), do: value
  def decode(value, :float, path, _opts, _source), do: type_error!(path, :float, value)

  def decode(value, :number, _path, _opts, _source) when is_number(value), do: value
  def decode(value, :number, path, _opts, _source), do: type_error!(path, :number, value)

  def decode(value, :boolean, _path, _opts, _source) when is_boolean(value), do: value
  def decode(value, :boolean, path, _opts, _source), do: type_error!(path, :boolean, value)

  def decode(nil, {:nullable, _type}, _path, _opts, _source), do: nil

  def decode(value, {:nullable, type}, path, opts, source),
    do: decode(value, type, path, opts, source)

  def decode(value, {:literal, literal}, _path, _opts, _source) when value == literal,
    do: value

  def decode(value, {:literal, literal}, path, _opts, _source),
    do: type_error!(path, {:literal, literal}, value)

  def decode(value, {:enum, values}, path, _opts, _source) do
    cond do
      value in values -> value
      is_binary(value) -> decode_atom_enum(value, values, path)
      true -> type_error!(path, {:enum, values}, value)
    end
  end

  def decode(value, {:one_of, types} = expected, path, opts, source) do
    result =
      Enum.reduce_while(types, :error, fn type, :error ->
        case decode_alternative(value, type, path, opts, source) do
          {:ok, _} = result -> {:halt, result}
          :error -> {:cont, :error}
        end
      end)

    case result do
      {:ok, decoded} -> decoded
      :error -> type_error!(path, expected, value)
    end
  end

  def decode(value, :atom, _path, _opts, _source) when is_atom(value), do: value

  def decode(value, :atom, path, opts, _source) when is_binary(value) do
    case Keyword.get(opts, :atom, :existing) do
      :existing -> String.to_existing_atom(value)
      {:enum, values} -> decode_atom_enum(value, values, path)
      other -> type_error!(path, {:atom_policy, other}, value)
    end
  rescue
    ArgumentError -> type_error!(path, :existing_atom, value)
  end

  def decode(value, :atom, path, _opts, _source), do: type_error!(path, :atom, value)

  def decode(values, {:list, type}, path, opts, source) when is_list(values) do
    decode_list(values, type, opts, source)
  rescue
    error in Error ->
      reraise locate_error(Enum.with_index(values), type, path, opts, source, error),
              __STACKTRACE__
  end

  def decode(value, {:list, type}, path, _opts, _source),
    do: type_error!(path, {:list, type}, value)

  def decode(value, {:map, key_type, value_type}, path, opts, source) when is_map(value) do
    decode_map_values(value, key_type, value_type, path, opts, source)
  rescue
    error in Error ->
      entries =
        Enum.map(value, fn {key, item} ->
          decoded_key = decode_key(key, key_type, path, opts, source)
          {map_value(item, decoded_key, source, opts), decoded_key}
        end)

      reraise locate_error(entries, value_type, path, opts, source, error), __STACKTRACE__
  end

  def decode(value, {:map, key_type, value_type}, path, _opts, _source) do
    type_error!(path, {:map, key_type, value_type}, value)
  end

  def decode(value, module, path, _opts, _source) when is_atom(module) do
    decode_module(value, module, path)
  end

  def decode(value, expected, path, _opts, _source), do: type_error!(path, expected, value)

  def decode_module(value, module, path) when is_atom(module) do
    cond do
      is_struct(value, module) -> value
      is_map(value) -> decode_codec(value, module, path)
      true -> type_error!(path, module, value)
    end
  end

  # Decodes a map through a nested codec without checking up front that
  # `module` is one: a module without `from_map!/1` is a type error. A nested
  # codec reports paths relative to itself, so prefix ours to name the field
  # from the root, however deep the nesting.
  def decode_codec(map, module, path) do
    module.from_map!(map)
  rescue
    error in Error ->
      reraise %{error | path: path ++ error.path}, __STACKTRACE__

    error in UndefinedFunctionError ->
      case error do
        %{module: ^module, function: :from_map!, arity: 1} -> type_error!(path, module, map)
        _other -> reraise error, __STACKTRACE__
      end
  end

  def type_error!(path, expected, value) do
    raise Error, path: path, expected: expected, got: value, reason: :invalid_type
  end

  defp decode_alternative(value, type, path, opts, source) do
    {:ok, decode(value, type, path, opts, source)}
  rescue
    _error in Error -> :error
  end

  # Elements decode relative to themselves, so successful decodes never build
  # paths. On failure, `locate_error/6` decodes the elements again to find
  # which one failed and prefixes its location.
  defp decode_list([], _type, _opts, _source), do: []

  defp decode_list([value | rest], type, opts, source),
    do: [decode(value, type, [], opts, source) | decode_list(rest, type, opts, source)]

  defp decode_map_values(map, key_type, value_type, path, opts, source) do
    Map.new(map, fn {key, item} ->
      decoded_key = decode_key(key, key_type, path, opts, source)
      item = map_value(item, decoded_key, source, opts)
      {decoded_key, decode(item, value_type, [], opts, source)}
    end)
  end

  defp locate_error(entries, type, path, opts, source, error) do
    Enum.find_value(entries, error, fn {value, key} ->
      try do
        decode(value, type, [], opts, source)
        nil
      rescue
        element_error in Error -> %{element_error | path: path ++ [key | element_error.path]}
      end
    end)
  end

  defp decode_key(key, :string, _path, _opts, _source) when is_binary(key), do: key
  defp decode_key(key, :atom, path, opts, source), do: decode(key, :atom, path, opts, source)
  defp decode_key(key, type, path, opts, source), do: decode(key, type, path, opts, source)

  defp map_value(value, key, source, opts) do
    case Keyword.get(opts, :values) do
      nil -> value
      {:local, module, fun, 3} -> apply(module, fun, [key, value, source])
      fun when is_function(fun, 3) -> fun.(key, value, source)
      fun when is_function(fun, 2) -> fun.(key, value)
    end
  end

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
