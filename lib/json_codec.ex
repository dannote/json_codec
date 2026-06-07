defmodule JSONCodec do
  @moduledoc """
  Compile-time generated codecs for JSON-shaped Elixir structs.

  `JSONCodec` is not a JSON parser. It uses `Jason` for JSON parsing and focuses on
  the part application code usually repeats by hand: turning decoded string-keyed maps
  into nested structs with defaults, aliases, computed fields, and explicit atom policy.
  """

  alias JSONCodec.Error

  @type field :: %{
          name: atom(),
          json: String.t(),
          type: term(),
          required: boolean(),
          default?: boolean(),
          default: term(),
          opts: keyword()
        }

  defmacro __using__(_opts) do
    quote do
      import JSONCodec, only: [field: 2, field: 3, computed: 2]
      Module.register_attribute(__MODULE__, :json_codec_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :json_codec_computed, accumulate: true)
      @before_compile JSONCodec
    end
  end

  defmacro field(name, type, opts \\ []) when is_atom(name) do
    caller = __CALLER__

    {type, _binding} =
      type
      |> Macro.prewalk(&Macro.expand(&1, caller))
      |> Code.eval_quoted([], caller)

    escaped_type = Macro.escape(type)
    escaped_opts = Macro.escape(opts)

    quote bind_quoted: [name: name, type: escaped_type, opts: escaped_opts] do
      @json_codec_fields {name, type, opts}
    end
  end

  defmacro computed(name, fun_ast) when is_atom(name) do
    escaped_fun = Macro.escape(fun_ast)

    quote bind_quoted: [name: name, fun_ast: escaped_fun] do
      @json_codec_computed {name, fun_ast}
    end
  end

  defmacro __before_compile__(env) do
    fields =
      env.module
      |> Module.get_attribute(:json_codec_fields)
      |> Enum.reverse()
      |> Enum.map(&normalize_field/1)

    computed =
      env.module
      |> Module.get_attribute(:json_codec_computed)
      |> Enum.reverse()

    struct_fields =
      Enum.map(fields, fn field ->
        if field.default? do
          {field.name, field.default}
        else
          {field.name, nil}
        end
      end) ++ Enum.map(computed, fn {name, _fun_ast} -> {name, nil} end)

    enforced = fields |> Enum.filter(& &1.required) |> Enum.map(& &1.name)
    build_pairs = Enum.map(fields, &field_pair_ast/1)
    computed_result = computed_result_ast(computed)
    escaped_fields = Macro.escape(fields)

    quote do
      @enforce_keys unquote(enforced)
      defstruct unquote(struct_fields)

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

  defp normalize_field({name, type, opts}) do
    default? = Keyword.has_key?(opts, :default)
    required = Keyword.get(opts, :required, not (Keyword.get(opts, :optional, false) or default?))

    %{
      name: name,
      json: Keyword.get(opts, :json, Atom.to_string(name)),
      type: type,
      required: required,
      default?: default?,
      default: Keyword.get(opts, :default),
      opts: opts
    }
  end

  defp field_pair_ast(field) do
    value_ast = field_value_ast(field)
    {field.name, value_ast}
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

    if field.required do
      quote do
        case unquote(defaulted) do
          nil -> nil
          value -> unquote(decoder).decode(value, unquote(type), unquote(path), unquote(opts))
        end
      end
    else
      quote do
        case unquote(defaulted) do
          :__json_codec_missing__ -> nil
          nil -> nil
          value -> unquote(decoder).decode(value, unquote(type), unquote(path), unquote(opts))
        end
      end
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
