# JSONCodec

[![HexDocs](https://img.shields.io/badge/hexdocs-json__codec-purple)](https://hexdocs.pm/json_codec/)

Compile-time generated codecs for JSON-shaped Elixir structs.

Agent instructions for consumers are available at <https://github.com/dannote/json_codec/blob/master/SKILL.md>. If your coding agent supports skills, load that file before adding JSON decoding code that depends on JSONCodec.

`JSONCodec` is **not** another JSON parser. It parses with Elixir's `JSON` module (or [`Jason`](https://hex.pm/packages/jason) before Elixir 1.18) and focuses on the annoying part that tends to be rewritten in every Elixir project: converting decoded string-keyed JSON maps into nested structs with aliases, defaults, computed fields, explicit atom policy, and schema export.

`JSONCodec` uses normal Elixir declarations as the source of truth:

- `defstruct` for fields and defaults
- `@type t` for field types; a field is required unless its type allows `nil` or it has a non-`nil` default
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
          name: :input | :acc | :result | nil,
          index: non_neg_integer() | nil
        }

  codec :name, atom: {:enum, [:input, :acc, :result]}
end
```

Generated API:

```elixir
FunctionID.decode!(json)
FunctionID.decode(json)
FunctionID.from_map!(map)
FunctionID.from_map(map)
FunctionID.dump(struct)
FunctionID.schema()
```

Top-level helpers are also available:

```elixir
JSONCodec.decode!(json, FunctionID)
JSONCodec.from_map!(map, FunctionID)
JSONCodec.dump(struct)
JSONCodec.schema(FunctionID)
```

## Why another JSON library?

Because this is not trying to compete with JSON parsers. It sits after parsing.

Most Elixir JSON code starts with `JSON.decode!/1` or `Jason.decode!/1`, then hand-rolls `from_map!/1` functions forever:

```elixir
def from_map!(%{"from" => from, "to" => to} = map) do
  %DataFlow{
    from: DataRef.from_map!(from),
    to: DataRef.from_map!(to),
    through: Enum.map(Map.get(map, "through", []), &DataRef.from_map!/1),
    variable_names: Map.get(map, "variable_names", [])
  }
end
```

`JSONCodec` generates that boring code from normal struct/typespec declarations.

| Library | Main job | Struct decode | Nested structs | Field aliases | Computed fields | Atom policy | Hot-path goal |
|---|---|---:|---:|---:|---:|---:|---:|
| `Jason` | JSON parser/encoder | No | No | No | No | key option only | parsing speed |
| `Poison` `as:` | parser + old struct decode | Yes | Limited | No | No | key option | legacy parser path |
| `Spectral` | typespec-driven serialization/schema | Yes | Yes | Yes | via codecs | safe existing atoms | validation/type coverage |
| `Exdantic`/`Elixact`/`Zoi`/`Drops` | validation frameworks | Sometimes | Yes | Sometimes | Yes | framework-specific | validation UX |
| `Tarams` | Phoenix params casting | Map output | Nested maps | Yes | transforms | casting-specific | request params |
| `SimpleSchema` | JSON validation + struct | Yes | Yes | Yes | custom callbacks | limited | validation pipeline |
| **JSONCodec** | generated JSON-shaped struct codecs | **Yes** | **Yes** | **Yes** | **Yes** | **explicit per field** | **near-handwritten decode** |

Use `JSON` or `Jason` for parsing. Use `Tarams`/`Ecto` for Phoenix params. Use a validation framework when rich validation is the main goal. Use `JSONCodec` when you own the struct shape and want fast, boring, explicit map-to-struct codecs.

## Codec metadata

Most fields need no JSONCodec-specific declaration. Defaults come from `defstruct`; types come from `@type t`.

```elixir
defmodule PackageManifest do
  use JSONCodec, case: :camel

  defstruct [:name, :version, dev_dependencies: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t() | nil,
          dev_dependencies: %{String.t() => String.t()}
        }
end
```

`:camel` maps `:dev_dependencies` to `"devDependencies"` automatically.

Use `dump/1` when converting codec-owned structs back to JSON-shaped Elixir data with the configured JSON field names:

```elixir
manifest = %PackageManifest{name: "demo", dev_dependencies: %{"jason" => "~> 1.4"}}

JSONCodec.dump(manifest)
#=> %{"name" => "demo", "version" => nil, "devDependencies" => %{"jason" => "~> 1.4"}}
```

Structs that are not codecs, such as `DateTime`, are returned unchanged so the JSON encoder serializes them.

Use `codec/2` for exceptions and special behavior:

```elixir
codec :id, as: "_id"
codec :variable_names, atom: {:enum, [:acc, :result]}
codec :created_at, as: "createdAtMs", cast: :from_milliseconds
codec :name, transform: :trim_name
```

Field processing order is:

```text
JSON key mapping -> raw value -> cast -> type decode -> transform -> struct field
```

Use `cast:` to convert a wire representation into the declared Elixir type before type decoding. A cast returns `{:ok, value}` for valid input and `:error` or `{:error, reason}` otherwise, like `Ecto.Type.cast/1`, so stdlib functions such as `DateTime.from_unix/2` can be returned directly:

```elixir
defmodule JobPayload do
  use JSONCodec, case: :camel

  defstruct [:id, :created_at]

  @type t :: %__MODULE__{id: String.t(), created_at: DateTime.t()}

  codec :created_at, as: "createdAtMs", cast: :from_milliseconds

  def from_milliseconds(milliseconds) when is_integer(milliseconds),
    do: DateTime.from_unix(milliseconds, :millisecond)

  def from_milliseconds(_milliseconds), do: :error
end
```

Invalid input becomes a `JSONCodec.Error` for that field with `reason: :invalid_value`, the full path from the root, and `details` holding the cast's `reason`:

```elixir
JobPayload.from_map(%{"id" => "1", "createdAtMs" => "soon"})
#=> {:error, %JSONCodec.Error{path: [:created_at], reason: :invalid_value, got: "soon", ...}}
```

Casts never need to know their path. Exceptions raised inside a cast are bugs and propagate unchanged; cover input you mean to reject with a clause that returns `:error`.

Use `transform:` to normalize a value after it has decoded as the declared type:

```elixir
codec :name, transform: :trim_name

def trim_name(name), do: String.trim(name)
```

Local callback atoms are expanded to functions in the same module:

```elixir
codec :created_at, cast: :from_milliseconds
# calls from_milliseconds(value) -> {:ok, value} | :error | {:error, reason}

codec :name, transform: :trim_name
# calls trim_name(value)

codec :icons, values: :icon_value
# calls icon_value(key, value, source_map)
```

Remote captures are also supported:

```elixir
codec :created_at, cast: &MyTransforms.from_milliseconds/1
codec :name, transform: &String.trim/1
codec :icons, values: &MyTransforms.icon_value/3
```

Atom policy is explicit. `atom()` fields accept only atoms that already exist (`:existing`, the default) or a fixed list; unknown policies are compile errors:

```elixir
codec :status, atom: :existing
codec :variable_name, atom: {:enum, [:acc, :result]}
```

Use `strict: true` when `from_map/1` should accept only JSON/string-keyed maps and reject atom-key fallback:

```elixir
defmodule StrictPayload do
  use JSONCodec, case: :camel, strict: true

  defstruct [:job_id]
  @type t :: %__MODULE__{job_id: String.t()}
end
```

### Advanced map value callbacks

For map fields, `values:` transforms each raw map value before `JSONCodec` decodes it as the declared value type:

```elixir
codec :icons, values: :icon_value
# icon_value(key, raw_value, source_map) -> raw_value_for_normal_decode
```

If that callback needs shared context, use `values_source:` to compute the third argument once per map field:

```elixir
codec :icons, values: :icon_value, values_source: :icon_defaults
# icon_defaults(source_map) -> defaults
# icon_value(key, raw_value, defaults) -> raw_value_for_normal_decode
```

For map-heavy data where a custom decoder is clearer or faster, `decode_values:` returns the final decoded map value directly:

```elixir
codec :icons, decode_values: :decode_icon, values_source: :icon_defaults
# icon_defaults(source_map) -> defaults
# decode_icon(key, raw_value, defaults) -> final decoded value
```

Remote captures work for these callbacks too:

```elixir
codec :icons, values: &MyTransforms.icon_value/3,
              values_source: &MyTransforms.icon_defaults/1

codec :icons, decode_values: &MyTransforms.decode_icon/3,
              values_source: &MyTransforms.icon_defaults/1
```

## Errors

`decode/1` and `from_map/1` return `{:ok, struct}` or `{:error, %JSONCodec.Error{}}`; the bang variants raise it. Every failure has the same shape:

```elixir
{:error, %JSONCodec.Error{path: [:data_flows, 3, :to, :type], reason: :invalid_type, expected: {:enum, [:argument, :return, :variable]}, got: "param"}}
```

- `path` names the field from the root, through nested structs, list indexes, and map keys.
- `reason` is `:missing_required_field`, `:invalid_type`, `:invalid_value` (a cast rejected the value), or `:invalid_json`.
- `details` holds a cast's rejection reason or the JSON parser's message.

## Supported type shapes

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
- mixed unions like `String.t() | integer()`
- `[type]`
- `%{String.t() => value_type}`
- another `JSONCodec` module via `Other.t()`

## Schema export

Each codec module exports a JSON Schema-compatible map:

```elixir
FunctionID.schema()
JSONCodec.schema(FunctionID)
```

A field typed as a module that is not a codec gets that module's schema if it implements the `JSONCodec.Schema` behaviour:

```elixir
defmodule Money do
  @behaviour JSONCodec.Schema

  @impl true
  def schema, do: %{"type" => "string", "pattern" => "^\\d+\\.\\d{2}$"}
end
```

This is intentionally compatible with the direction of `JSONSpec`: codecs are the fast construction layer; schema validation can remain a separate layer.

## Benchmarks

Run:

```sh
MIX_ENV=dev mix run bench/program_facts_like.exs
```

Machine used for this snapshot: Apple M5, Elixir 1.20, Erlang/OTP 29. Payload: `142 KB`, 250 nested `data_flow` records.

| Case | avg | median | memory |
|---|---:|---:|---:|
| handwritten map→struct | 235 µs | 228 µs | 0.25 MB |
| `JSONCodec` map→struct | 251 µs | 264 µs | 0.35 MB |
| `JSON.decode` only | 500 µs | 499 µs | 0.83 MB |
| `Jason.decode` only | 730 µs | 699 µs | 1.10 MB |
| `JSONCodec.decode!` | 869 µs | 870 µs | 1.18 MB |
| handwritten `JSON`+struct | 912 µs | 860 µs | 1.07 MB |
| handwritten `Jason`+struct | 1087 µs | 1069 µs | 1.34 MB |
| `Spectral` pre-decoded | 1273 µs | 1208 µs | 3.23 MB |
| `Spectral` native JSON | 1613 µs | 1441 µs | 4.06 MB |

Interpretation:

- On decoded maps, `JSONCodec` is within about 1.1× of this handwritten decoder, doing fewer BEAM reductions but allocating about 1.4× the memory.
- End-to-end, parsing dominates. `JSONCodec.decode!/1` parses with Elixir's `JSON` module and is on par with handwritten `JSON`+struct, faster than handwritten `Jason`+struct, and about 1.9× faster than `Spectral` native JSON on this shape.
- On map-heavy Iconify-like data (`mix run bench/iconify_like.exs`), `JSONCodec` with `decode_values:` and `values_source:` is tied with the handwritten decoder and uses slightly less memory.

## Installation

```elixir
{:json_codec, "~> 0.3"}
```

On Elixir 1.18+ no JSON dependency is needed. On earlier versions, add `{:jason, "~> 1.4"}`.

## Development

See [CHANGELOG.md](CHANGELOG.md) for release notes.

This project was bootstrapped with VibeKit conventions.

```sh
mix deps.get
mix test
mix ci
```
