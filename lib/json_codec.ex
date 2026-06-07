defmodule JSONCodec do
  @moduledoc """
  Compile-time generated codecs for JSON-shaped Elixir structs.

  `JSONCodec` is not a JSON parser. It uses `Jason` for JSON parsing and focuses on
  the part application code usually repeats by hand: turning decoded string-keyed maps
  into nested structs with defaults, aliases, computed fields, explicit atom policy, and
  schema export.
  """

  alias JSONCodec.Error

  @missing :__json_codec_missing__

  defmacro __using__(opts \\ []) do
    opts = Macro.expand(opts, __CALLER__)

    quote bind_quoted: [opts: opts] do
      import Kernel, except: [defstruct: 1]
      import JSONCodec, only: [defstruct: 1, codec: 2, computed: 2]

      Module.register_attribute(__MODULE__, :json_codec_struct_fields, accumulate: false)
      Module.register_attribute(__MODULE__, :json_codec_options, accumulate: false)
      Module.register_attribute(__MODULE__, :json_codec_field_options, accumulate: true)
      Module.register_attribute(__MODULE__, :json_codec_computed, accumulate: true)

      @json_codec_options opts
      @before_compile JSONCodec
    end
  end

  defmacro defstruct(fields) do
    escaped_fields = Macro.escape(fields)

    quote bind_quoted: [fields: escaped_fields] do
      @json_codec_struct_fields fields
      Kernel.defstruct(fields)
    end
  end

  defmacro codec(name, opts) when is_atom(name) do
    caller = __CALLER__
    {opts, _binding} = Code.eval_quoted(opts, [], caller)

    quote bind_quoted: [name: name, opts: Macro.escape(opts)] do
      @json_codec_field_options {name, opts}
    end
  end

  defmacro computed(name, fun_ast) when is_atom(name) do
    escaped_fun = Macro.escape(fun_ast)

    quote bind_quoted: [name: name, fun_ast: escaped_fun] do
      @json_codec_computed {name, fun_ast}
    end
  end

  defmacro __before_compile__(env) do
    env
    |> before_compile_context()
    |> generated_codec_ast()
  end

  defp before_compile_context(env) do
    module = env.module
    codec_options = Module.get_attribute(module, :json_codec_options) || []
    struct_fields = Module.get_attribute(module, :json_codec_struct_fields) || []
    field_options = field_options(module)
    computed = computed_fields(module)
    type_fields = parse_type_fields(module, env)
    fields = build_fields(module, struct_fields, type_fields, field_options, codec_options, env)

    %{
      fields: fields,
      build_pairs: Enum.map(fields, &field_pair_ast/1),
      computed_result: computed_result_ast(computed)
    }
  end

  defp field_options(module) do
    module
    |> Module.get_attribute(:json_codec_field_options)
    |> Enum.reverse()
    |> Map.new()
  end

  defp computed_fields(module) do
    module
    |> Module.get_attribute(:json_codec_computed)
    |> Enum.reverse()
  end

  defp generated_codec_ast(%{
         fields: fields,
         build_pairs: build_pairs,
         computed_result: computed_result
       }) do
    escaped_fields = Macro.escape(fields)

    quote do
      @doc false
      def __json_codec_fields__, do: unquote(escaped_fields)

      @doc "Decodes a JSON string into this struct."
      def decode(json) when is_binary(json) do
        JSONCodec.decode(json, __MODULE__)
      end

      @doc "Decodes a JSON string into this struct, raising on failure."
      def decode!(json) when is_binary(json) do
        JSONCodec.decode!(json, __MODULE__)
      end

      @doc "Builds this struct from a decoded JSON map."
      def from_map(map) when is_map(map) do
        JSONCodec.from_map(map, __MODULE__)
      end

      @doc "Builds this struct from a decoded JSON map, raising on failure."
      def from_map!(map) when is_map(map) do
        struct = %__MODULE__{unquote_splicing(build_pairs)}
        unquote(computed_result)
      end

      @doc "Converts this struct into a JSON-shaped map."
      def to_map(%__MODULE__{} = struct) do
        JSONCodec.to_map(struct)
      end

      @doc "Returns a JSON Schema-compatible schema map."
      def json_schema do
        JSONCodec.Schema.object(__MODULE__)
      end
    end
  end

  @doc "Decodes a JSON string into `module`."
  def decode(json, module) when is_binary(json) and is_atom(module) do
    with {:ok, map} <- Jason.decode(json) do
      from_map(map, module)
    end
  end

  @doc "Decodes a JSON string into `module`, raising on failure."
  def decode!(json, module) when is_binary(json) and is_atom(module) do
    json
    |> Jason.decode!()
    |> from_map!(module)
  end

  @doc "Builds `module` from a decoded JSON map."
  def from_map(map, module) when is_map(map) and is_atom(module) do
    {:ok, from_map!(map, module)}
  rescue
    error in [Error] -> {:error, error}
  end

  @doc "Builds `module` from a decoded JSON map, raising on failure."
  def from_map!(map, module) when is_map(map) and is_atom(module), do: module.from_map!(map)

  @doc "Converts a struct or value into JSON-shaped Elixir data."
  def to_map(value)
  def to_map(%_{} = struct), do: struct |> Map.from_struct() |> to_map()
  def to_map(%{} = map), do: Map.new(map, fn {key, value} -> {encode_key(key), to_map(value)} end)
  def to_map(values) when is_list(values), do: Enum.map(values, &to_map/1)
  def to_map(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def to_map(value), do: value

  @doc "Returns a JSON Schema-compatible schema map for a JSONCodec module."
  def json_schema(module), do: JSONCodec.Schema.object(module)

  defp build_fields(module, struct_fields, type_fields, field_options, codec_options, env) do
    defaults = struct_defaults(struct_fields)
    field_names = Map.keys(defaults)

    Enum.map(field_names, fn name ->
      opts = Map.get(field_options, name, []) |> normalize_callbacks(module, name, env)
      type = Map.get(type_fields, name, :any)
      default = Map.fetch!(defaults, name)
      default? = default != @missing
      nullable? = nullable_type?(type)

      %{
        name: name,
        json: Keyword.get(opts, :as, json_key(name, codec_options)),
        type: type,
        required: not default? and not nullable?,
        default?: default?,
        default: if(default?, do: default, else: nil),
        opts: opts,
        module: module
      }
    end)
  end

  defp struct_defaults(fields) when is_list(fields) do
    Map.new(fields, fn
      {name, default} when is_atom(name) -> {name, default}
      name when is_atom(name) -> {name, @missing}
    end)
  end

  defp normalize_callbacks(opts, module, field, env) do
    opts
    |> normalize_callback(:transform, 1, module, field, env)
    |> normalize_callback(:values, 3, module, field, env)
  end

  defp normalize_callback(opts, key, arity, module, field, env) do
    case Keyword.fetch(opts, key) do
      :error ->
        opts

      {:ok, fun} when is_atom(fun) ->
        Keyword.put(opts, key, {:local, module, fun, arity})

      {:ok, fun} when is_function(fun, arity) ->
        opts

      {:ok, other} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "invalid JSONCodec option #{inspect(key)} for #{inspect(field)}. " <>
              "Expected a local function name atom or remote capture with arity #{arity}, got: #{inspect(other)}"
    end
  end

  defp parse_type_fields(module, env) do
    env.module
    |> Module.get_attribute(:type)
    |> Enum.find_value(%{}, fn
      {:type, {:"::", _, [{:t, _, _}, type_ast]}, _} -> parse_struct_type(type_ast, module, env)
      _other -> nil
    end)
  end

  defp parse_struct_type({:%, _, [_module_ast, {:%{}, _, fields}]}, _module, env) do
    Map.new(fields, fn {name, type_ast} -> {name, normalize_type(type_ast, env)} end)
  end

  defp parse_struct_type(_type_ast, _module, _env), do: %{}

  defp normalize_type({:|, _, _} = union, env) do
    values = union |> collect_union() |> Enum.map(&normalize_type(&1, env))
    non_nil = Enum.reject(values, &is_nil/1)

    type =
      case non_nil do
        [single] ->
          single

        values ->
          if enum_values?(values), do: {:enum, flatten_enum(values)}, else: {:one_of, values}
      end

    if Enum.any?(values, &is_nil/1), do: {:nullable, type}, else: type
  end

  defp normalize_type([type], env), do: {:list, normalize_type(type, env)}

  defp normalize_type({:%{}, _, [{:"=>", _, [key_type, value_type]}]}, env) do
    {:map, normalize_type(key_type, env), normalize_type(value_type, env)}
  end

  defp normalize_type({:%{}, _, [{key_type, value_type}]}, env) do
    {:map, normalize_type(key_type, env), normalize_type(value_type, env)}
  end

  defp normalize_type({name, _, []}, _env)
       when name in [
              :integer,
              :non_neg_integer,
              :pos_integer,
              :float,
              :number,
              :boolean,
              :atom,
              :any,
              :term
            ],
       do: name

  defp normalize_type({{:., _, [{:__aliases__, _, [:String]}, :t]}, _, []}, _env), do: :string

  defp normalize_type({{:., _, [module_ast, :t]}, _, []}, env) do
    Macro.expand(module_ast, env)
  end

  defp normalize_type(nil, _env), do: nil
  defp normalize_type(atom, _env) when is_atom(atom), do: atom
  defp normalize_type(_other, _env), do: :any

  defp collect_union({:|, _, [left, right]}), do: collect_union(left) ++ collect_union(right)
  defp collect_union(other), do: [other]

  defp enum_values?(values), do: Enum.all?(values, &is_atom/1) and nil not in values

  defp flatten_enum(values) do
    values
    |> Enum.flat_map(fn
      {:enum, nested} -> nested
      value -> [value]
    end)
    |> Enum.uniq()
  end

  defp nullable_type?({:nullable, _type}), do: true
  defp nullable_type?(_type), do: false

  defp json_key(name, opts) do
    case Keyword.get(opts, :case, :snake) do
      :snake -> Atom.to_string(name)
      :camel -> camelize(name)
    end
  end

  defp camelize(name) do
    [first | rest] = name |> Atom.to_string() |> String.split("_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end

  defp field_pair_ast(field) do
    {field.name, field_value_ast(field)}
  end

  defp field_value_ast(field) do
    decoder = quote(do: JSONCodec.Decoder)
    atom = field.name
    json = field.json
    type = Macro.escape(field.type)
    opts = Macro.escape(field.opts)
    path = [field.name]

    raw =
      quote do
        unquote(decoder).fetch_field(map, unquote(atom), unquote(json))
      end

    present =
      if field.required do
        quote do
          unquote(decoder).required!(unquote(raw), unquote(path), unquote(type))
        end
      else
        raw
      end

    defaulted =
      if field.default? do
        quote do
          unquote(decoder).default(unquote(present), unquote(Macro.escape(field.default)))
        end
      else
        present
      end

    decoded =
      if field.required do
        quote do
          case unquote(defaulted) do
            nil ->
              nil

            value ->
              unquote(decoder).decode(value, unquote(type), unquote(path), unquote(opts), map)
          end
        end
      else
        quote do
          case unquote(defaulted) do
            :__json_codec_missing__ ->
              nil

            nil ->
              nil

            value ->
              unquote(decoder).decode(value, unquote(type), unquote(path), unquote(opts), map)
          end
        end
      end

    transform_ast(decoded, Keyword.get(field.opts, :transform))
  end

  defp transform_ast(decoded, nil), do: decoded

  defp transform_ast(decoded, {:local, module, fun, _arity}) do
    quote do
      unquote(module).unquote(fun)(unquote(decoded))
    end
  end

  defp transform_ast(decoded, transform) do
    transform = Macro.escape(transform)

    quote do
      unquote(transform).(unquote(decoded))
    end
  end

  defp computed_result_ast(computed) do
    Enum.reduce(computed, quote(do: struct), fn {name, fun_ast}, acc ->
      quote do
        value = unquote(acc)
        %{value | unquote(name) => unquote(fun_ast).(value)}
      end
    end)
  end

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: key
end
