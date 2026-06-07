# JSONCodec

Compile-time generated codecs for JSON-shaped Elixir structs.

`JSONCodec` is **not** another JSON parser. It uses [`Jason`](https://hex.pm/packages/jason) for parsing and focuses on the annoying part that tends to be rewritten in every Elixir project: converting decoded string-keyed JSON maps into nested structs with aliases, defaults, computed fields, explicit atom policy, and schema export.

JSONCodec uses normal Elixir declarations as the source of truth:

- `defstruct` for fields and defaults
- `@type t` for field types
- `codec/2` only for JSON-specific field metadata

```elixir
defmodule FunctionID do
  use JSONCodec

  defstruct [:module, :function, :arity, :id]

  @type t :: %__MODULE__{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          id: String.t() | nil
        }

  computed :id, fn function ->
    "#{function.module}.#{function.function}/#{function.arity}"
  end
end

defmodule DataRef do
  use JSONCodec

  defstruct [:type, :function, :name, :index]

  @type t :: %__MODULE__{
          type: :argument | :return | :variable,
          function: FunctionID.t(),
          name: atom() | nil,
          index: non_neg_integer() | nil
        }

  codec :name, atom: :unsafe
end
```

Generated API:

```elixir
FunctionID.decode!(json)
FunctionID.decode(json)
FunctionID.from_map!(map)
FunctionID.from_map(map)
FunctionID.to_map(struct)
FunctionID.json_schema()
```

Top-level helpers are also available:

```elixir
JSONCodec.decode!(json, FunctionID)
JSONCodec.from_map!(map, FunctionID)
JSONCodec.json_schema(FunctionID)
```

## Why another JSON library?

Because this is not trying to compete with JSON parsers. It sits after parsing.

Most Elixir JSON code starts with `Jason.decode!/1`, then hand-rolls `from_map!/1` functions forever:

```elixir
def from_map!(%{"from" => from, "to" => to} = map) do
  %DataFlow{
    from: DataRef.from_map!(from),
    to: DataRef.from_map!(to),
    through: Enum.map(Map.get(map, "through", []), &DataRef.from_map!/1),
    variable_names: Enum.map(Map.get(map, "variable_names", []), &String.to_atom/1)
  }
end
```

`JSONCodec` generates that boring code from normal struct/typespec declarations.

| Library | Main job | Struct decode | Nested structs | Field aliases | Computed fields | Atom policy | Hot-path goal |
|---|---|---:|---:|---:|---:|---:|---:|
| Jason | JSON parser/encoder | No | No | No | No | key option only | parsing speed |
| Poison `as:` | parser + old struct decode | Yes | Limited | No | No | key option | legacy parser path |
| Spectral | typespec-driven serialization/schema | Yes | Yes | Yes | via codecs | safe existing atoms | validation/type coverage |
| Exdantic/Elixact/Zoi/Drops | validation frameworks | Sometimes | Yes | Sometimes | Yes | framework-specific | validation UX |
| Tarams | Phoenix params casting | Map output | Nested maps | Yes | transforms | casting-specific | request params |
| SimpleSchema | JSON validation + struct | Yes | Yes | Yes | custom callbacks | limited | validation pipeline |
| **JSONCodec** | generated JSON-shaped struct codecs | **Yes** | **Yes** | **Yes** | **Yes** | **explicit per field** | **near-handwritten decode** |

Use Jason for parsing. Use Tarams/Ecto for Phoenix params. Use a validation framework when rich validation is the main goal. Use `JSONCodec` when you own the struct shape and want fast, boring, explicit map-to-struct codecs.

## Codec metadata

Most fields need no JSONCodec-specific declaration. Defaults come from `defstruct`; types come from `@type t`.

```elixir
defmodule PackageManifest do
  use JSONCodec, case: :camel, fast_path: :json

  defstruct [:name, :version, dev_dependencies: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t() | nil,
          dev_dependencies: %{String.t() => String.t()}
        }
end
```

`:camel` maps `:dev_dependencies` to `"devDependencies"` automatically.

`fast_path: :json` generates an optimized first `from_map!/1` clause for normal Jason-decoded JSON maps with string keys. If that fast string-key clause does not match, JSONCodec falls back to the full generic decoder, including atom-key lookup and detailed missing-field handling.

Use `codec/2` for exceptions and special behavior:

```elixir
codec :not_found, as: "not_found"
codec :variable_names, atom: :unsafe
codec :rotate, transform: :normalize_rotate
codec :icons, values: :icon_value
codec :icons, values: :icon_value, values_source: :icon_defaults
```

Local callback atoms are expanded to functions in the same module:

```elixir
codec :rotate, transform: :normalize_rotate
# calls normalize_rotate(value)

codec :icons, values: :icon_value
# calls icon_value(key, value, source_map)

codec :icons, values: :icon_value, values_source: :icon_defaults
# calls icon_defaults(source_map) once, then icon_value(key, value, defaults) for each entry
```

Remote captures are also supported:

```elixir
codec :rotate, transform: &MyTransforms.normalize_rotate/1
codec :icons, values: &MyTransforms.icon_value/3
codec :icons, values: &MyTransforms.icon_value/3, values_source: &MyTransforms.icon_defaults/1
```

Atom policy is explicit:

```elixir
codec :status, atom: :existing
codec :variable_name, atom: :unsafe
```

`:unsafe` uses `String.to_atom/1`; only use it for bounded/trusted internal data.

## Supported MVP type shapes

Read from `@type t`:

- `String.t()`
- `integer()`
- `non_neg_integer()`
- `pos_integer()`
- `float()`
- `number()`
- `boolean()`
- `atom()`
- `any()` / `term()`
- `type | nil`
- atom unions like `:active | :inactive`
- `[type]`
- `%{String.t() => value_type}`
- another `JSONCodec` module via `Other.t()`

## Schema export

Each codec module exports a JSON Schema-compatible map:

```elixir
FunctionID.json_schema()
JSONCodec.json_schema(FunctionID)
```

This is intentionally compatible with the direction of `JSONSpec`: codecs are the fast construction layer; schema validation can remain a separate layer.

## Benchmarks

Run:

```sh
MIX_ENV=dev mix run bench/program_facts_like.exs
```

Machine used for this snapshot: Apple M5, Elixir 1.20, Erlang/OTP 29. Payload: `142 KB`, 250 nested `data_flow` records.

| Case | ips | avg | memory |
|---|---:|---:|---:|
| JSONCodec map→struct | 4119.81 | 0.24 ms | 0.35 MB |
| handwritten map→struct | 4009.64 | 0.25 ms | 0.25 MB |
| Jason.decode only | 1378.28 | 0.73 ms | 1.10 MB |
| Spectral pre-decoded | 1252.96 | 0.80 ms | 3.23 MB |
| handwritten Jason+struct | 980.43 | 1.02 ms | 1.34 MB |
| JSONCodec Jason+struct | 972.52 | 1.03 ms | 1.45 MB |
| Spectral native JSON | 654.31 | 1.53 ms | 4.06 MB |

Interpretation:

- With `fast_path: :json`, `JSONCodec` is roughly tied with this handwritten decoder on decoded JSON maps, while still providing a generic fallback path.
- End-to-end, JSON parsing dominates. `JSONCodec.decode!/1` is within ~1.01× of handwritten Jason+struct in this MVP and ~1.49× faster than Spectral native JSON on this shape.
- On map-heavy Iconify-like data (`mix run bench/iconify_like.exs`), `values_source:` avoids recomputing inherited defaults for every map entry. JSONCodec still trails handwritten there because it keeps nested field validation and generic callback semantics, but the benchmark exists to keep future optimization honest across a different shape.
- The goal is not to beat perfect handwritten code on every shape immediately; it is to make the generated path close enough that hand-written decoders disappear.

## Installation

Not published yet. For now:

```elixir
{:json_codec, path: "../json_codec"}
```

## Development

This project was bootstrapped with VibeKit conventions.

```sh
mix deps.get
mix test
mix ci
```
