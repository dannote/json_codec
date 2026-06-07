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
      fast_build_pairs: fast_path_field_pairs(fields, codec_options),
      fast_pattern: fast_path_pattern(fields, codec_options),
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
         fast_build_pairs: fast_build_pairs,
         fast_pattern: fast_pattern,
         computed_result: computed_result
       }) do
    escaped_fields = Macro.escape(fields)
    fast_from_map = fast_from_map_ast(fast_pattern, fast_build_pairs, computed_result)

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
      unquote(fast_from_map)

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
    |> normalize_callback(:values_source, 1, module, field, env)
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

  defp fast_path_field_pairs(fields, opts) do
    required = required_fields(fields)

    if Keyword.get(opts, :fast_path) == :json and required != [] do
      required_vars = Map.new(required, &{&1.name, Macro.var(&1.name, nil)})
      Enum.map(fields, &field_pair_ast(&1, fast_path_raw(&1, required_vars)))
    end
  end

  defp fast_path_pattern(fields, opts) do
    required = required_fields(fields)

    if Keyword.get(opts, :fast_path) == :json and required != [] do
      {:%{}, [], Enum.map(required, &{&1.json, Macro.var(&1.name, nil)})}
    end
  end

  defp fast_path_raw(field, required_vars) do
    case Map.fetch(required_vars, field.name) do
      {:ok, var} ->
        {:raw, var}

      :error ->
        {:json, field.json}
    end
  end

  defp required_fields(fields), do: Enum.filter(fields, & &1.required)

  defp fast_from_map_ast(nil, _build_pairs, _computed_result), do: nil

  defp fast_from_map_ast(pattern, build_pairs, computed_result) do
    quote do
      def from_map!(unquote(pattern) = map) do
        struct = %__MODULE__{unquote_splicing(build_pairs)}
        unquote(computed_result)
      end
    end
  end

  defp field_pair_ast(field), do: field_pair_ast(field, :generic)

  defp field_pair_ast(field, raw_strategy) do
    {field.name, field_value_ast(field, raw_strategy)}
  end

  defp field_value_ast(field, raw_strategy) do
    decoder = quote(do: JSONCodec.Decoder)
    type = Macro.escape(field.type)
    path = [field.name]

    raw = raw_value_ast(raw_strategy, decoder, field.name, field.json)
    present = present_field_ast(raw, raw_strategy, field, decoder, path, type)
    defaulted = defaulted_field_ast(present, field, decoder)
    decoded = decoded_field_ast(defaulted, field, path)

    transform_ast(decoded, Keyword.get(field.opts, :transform))
  end

  defp present_field_ast(raw, raw_strategy, field, decoder, path, type) do
    cond do
      match?({:raw, _}, raw_strategy) ->
        raw

      field.required ->
        quote do
          unquote(decoder).required!(unquote(raw), unquote(path), unquote(type))
        end

      true ->
        raw
    end
  end

  defp defaulted_field_ast(present, %{default?: true, default: default}, decoder) do
    quote do
      unquote(decoder).default(unquote(present), unquote(Macro.escape(default)))
    end
  end

  defp defaulted_field_ast(present, _field, _decoder), do: present

  defp decoded_field_ast(defaulted, %{required: true} = field, path) do
    quote do
      value = unquote(defaulted)

      unquote(decode_value_ast(quote(do: value), field.type, path, field.opts, quote(do: map)))
    end
  end

  defp decoded_field_ast(defaulted, field, path) do
    decode_type = non_nil_type(field.type)

    quote do
      case unquote(defaulted) do
        :__json_codec_missing__ ->
          nil

        nil ->
          nil

        value ->
          unquote(
            decode_value_ast(quote(do: value), decode_type, path, field.opts, quote(do: map))
          )
      end
    end
  end

  defp raw_value_ast({:raw, value}, _decoder, _atom, _json), do: value

  defp raw_value_ast({:json, json}, _decoder, _atom, _json) do
    quote do
      :maps.get(unquote(json), map, :__json_codec_missing__)
    end
  end

  defp raw_value_ast(:generic, decoder, atom, json) do
    quote do
      unquote(decoder).fetch_field(map, unquote(atom), unquote(json))
    end
  end

  defp non_nil_type({:nullable, type}), do: type
  defp non_nil_type(type), do: type

  defp decode_value_ast(value, :string, path, _opts, _source) do
    quote do
      case unquote(value) do
        string when is_binary(string) -> string
        other -> JSONCodec.Decoder.type_error!(unquote(path), :string, other)
      end
    end
  end

  defp decode_value_ast(value, :integer, path, _opts, _source) do
    quote do
      case unquote(value) do
        integer when is_integer(integer) -> integer
        other -> JSONCodec.Decoder.type_error!(unquote(path), :integer, other)
      end
    end
  end

  defp decode_value_ast(value, :non_neg_integer, path, _opts, _source) do
    quote do
      case unquote(value) do
        integer when is_integer(integer) and integer >= 0 -> integer
        other -> JSONCodec.Decoder.type_error!(unquote(path), :non_neg_integer, other)
      end
    end
  end

  defp decode_value_ast(value, :pos_integer, path, _opts, _source) do
    quote do
      case unquote(value) do
        integer when is_integer(integer) and integer > 0 -> integer
        other -> JSONCodec.Decoder.type_error!(unquote(path), :pos_integer, other)
      end
    end
  end

  defp decode_value_ast(value, :boolean, path, _opts, _source) do
    quote do
      case unquote(value) do
        boolean when is_boolean(boolean) -> boolean
        other -> JSONCodec.Decoder.type_error!(unquote(path), :boolean, other)
      end
    end
  end

  defp decode_value_ast(value, :atom, path, [atom: :unsafe], _source) do
    quote do
      case unquote(value) do
        atom when is_atom(atom) -> atom
        string when is_binary(string) -> String.to_atom(string)
        other -> JSONCodec.Decoder.type_error!(unquote(path), :atom, other)
      end
    end
  end

  defp decode_value_ast(value, {:enum, values} = type, path, _opts, _source) do
    fallback = Macro.var(:other, nil)

    clauses =
      values
      |> Enum.flat_map(fn atom ->
        [
          {:->, [], [[atom], atom]},
          {:->, [], [[Atom.to_string(atom)], atom]}
        ]
      end)
      |> Kernel.++([
        {:->, [],
         [
           [fallback],
           quote(
             do:
               JSONCodec.Decoder.type_error!(
                 unquote(path),
                 unquote(Macro.escape(type)),
                 unquote(fallback)
               )
           )
         ]}
      ])

    {:case, [], [value, [do: clauses]]}
  end

  defp decode_value_ast(value, {:map, :string, module} = type, path, opts, source)
       when is_atom(module) do
    if primitive_type?(module),
      do: generic_decode_ast(value, type, path, opts, source),
      else: map_module_decode_ast(value, module, type, path, opts, source)
  end

  defp decode_value_ast(value, {:list, :atom} = type, path, [atom: :unsafe], _source) do
    quote do
      case unquote(value) do
        values when is_list(values) ->
          Enum.map(values, fn
            atom when is_atom(atom) ->
              atom

            string when is_binary(string) ->
              String.to_atom(string)

            other ->
              JSONCodec.Decoder.type_error!(unquote(path), unquote(Macro.escape(type)), other)
          end)

        other ->
          JSONCodec.Decoder.type_error!(unquote(path), unquote(Macro.escape(type)), other)
      end
    end
  end

  defp decode_value_ast(value, {:list, module} = type, path, _opts, _source)
       when is_atom(module) do
    if primitive_type?(module),
      do: generic_decode_ast(value, type, path, [], quote(do: map)),
      else: list_module_decode_ast(value, module, type, path)
  end

  defp decode_value_ast(value, {:nullable, type}, path, opts, source) do
    quote do
      case unquote(value) do
        nil -> nil
        value -> unquote(decode_value_ast(quote(do: value), type, path, opts, source))
      end
    end
  end

  defp decode_value_ast(value, module, path, opts, source) when is_atom(module) do
    if primitive_type?(module) do
      generic_decode_ast(value, module, path, opts, source)
    else
      quote do
        case unquote(value) do
          map when is_map(map) -> unquote(module).from_map!(map)
          other -> JSONCodec.Decoder.type_error!(unquote(path), unquote(module), other)
        end
      end
    end
  end

  defp decode_value_ast(value, type, path, opts, source) do
    generic_decode_ast(value, type, path, opts, source)
  end

  defp list_module_decode_ast(value, module, type, path) do
    quote do
      case unquote(value) do
        values when is_list(values) ->
          Enum.map(values, fn
            map when is_map(map) ->
              unquote(module).from_map!(map)

            other ->
              JSONCodec.Decoder.type_error!(unquote(path), unquote(Macro.escape(type)), other)
          end)

        other ->
          JSONCodec.Decoder.type_error!(unquote(path), unquote(Macro.escape(type)), other)
      end
    end
  end

  defp map_module_decode_ast(value, module, type, path, opts, source) do
    quote do
      case unquote(value) do
        entries when is_map(entries) ->
          values_source = unquote(values_source_ast(source, opts))

          Map.new(entries, fn
            {key, item} when is_binary(key) ->
              item =
                unquote(
                  map_value_ast(quote(do: item), quote(do: key), quote(do: values_source), opts)
                )

              {key, unquote(module).from_map!(item)}

            {key, _item} ->
              JSONCodec.Decoder.type_error!(unquote(path), unquote(Macro.escape(type)), key)
          end)

        other ->
          JSONCodec.Decoder.type_error!(unquote(path), unquote(Macro.escape(type)), other)
      end
    end
  end

  defp values_source_ast(source, opts) do
    case Keyword.get(opts, :values_source) do
      nil ->
        source

      {:local, module, fun, 1} ->
        quote do
          unquote(module).unquote(fun)(unquote(source))
        end

      transform ->
        quote do
          unquote(Macro.escape(transform)).(unquote(source))
        end
    end
  end

  defp map_value_ast(item, key, source, opts) do
    case Keyword.get(opts, :values) do
      nil ->
        item

      {:local, module, fun, 3} ->
        quote do
          unquote(module).unquote(fun)(unquote(key), unquote(item), unquote(source))
        end

      transform ->
        quote do
          unquote(Macro.escape(transform)).(unquote(key), unquote(item), unquote(source))
        end
    end
  end

  defp generic_decode_ast(value, type, path, opts, source) do
    quote do
      JSONCodec.Decoder.decode(
        unquote(value),
        unquote(Macro.escape(type)),
        unquote(path),
        unquote(Macro.escape(opts)),
        unquote(source)
      )
    end
  end

  defp primitive_type?(type) do
    type in [
      :any,
      :term,
      :string,
      :integer,
      :non_neg_integer,
      :pos_integer,
      :float,
      :number,
      :boolean,
      :atom
    ]
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
