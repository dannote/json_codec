# JSONCodec

[![HexDocs](https://img.shields.io/badge/hexdocs-json__codec-purple)](https://hexdocs.pm/json_codec/)

Compile-time generated codecs for JSON-shaped Elixir structs.

Agent instructions for consumers are available at <https://github.com/dannote/json_codec/blob/main/SKILL.md>. If your coding agent supports skills, load that file before adding JSON decoding code that depends on JSONCodec.

`JSONCodec` is **not** another JSON parser. It uses [`Jason`](https://hex.pm/packages/jason) for parsing and focuses on the annoying part that tends to be rewritten in every Elixir project: converting decoded string-keyed JSON maps into nested structs with aliases, defaults, computed fields, explicit atom policy, and schema export.

`JSONCodec` uses normal Elixir declarations as the source of truth:

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
FunctionID.schema()
```

Top-level helpers are also available:

```elixir
JSONCodec.decode!(json, FunctionID)
JSONCodec.from_map!(map, FunctionID)
JSONCodec.schema(FunctionID)
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
| `Jason` | JSON parser/encoder | No | No | No | No | key option only | parsing speed |
| `Poison` `as:` | parser + old struct decode | Yes | Limited | No | No | key option | legacy parser path |
| `Spectral` | typespec-driven serialization/schema | Yes | Yes | Yes | via codecs | safe existing atoms | validation/type coverage |
| `Exdantic`/`Elixact`/`Zoi`/`Drops` | validation frameworks | Sometimes | Yes | Sometimes | Yes | framework-specific | validation UX |
| `Tarams` | Phoenix params casting | Map output | Nested maps | Yes | transforms | casting-specific | request params |
| `SimpleSchema` | JSON validation + struct | Yes | Yes | Yes | custom callbacks | limited | validation pipeline |
| **JSONCodec** | generated JSON-shaped struct codecs | **Yes** | **Yes** | **Yes** | **Yes** | **explicit per field** | **near-handwritten decode** |

Use `Jason` for parsing. Use `Tarams`/`Ecto` for Phoenix params. Use a validation framework when rich validation is the main goal. Use `JSONCodec` when you own the struct shape and want fast, boring, explicit map-to-struct codecs.

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

Use `dump/1` when converting codec-owned structs back to JSON-shaped Elixir data with the configured JSON field names:

```elixir
manifest = %PackageManifest{name: "demo", dev_dependencies: %{"jason" => "~> 1.4"}}

JSONCodec.dump(manifest)
#=> %{"name" => "demo", "version" => nil, "devDependencies" => %{"jason" => "~> 1.4"}}
```

`to_map/1` remains a compatibility helper that stringifies atom keys recursively.

`fast_path: :json` generates an optimized first `from_map!/1` clause for normal `Jason`-decoded JSON maps with string keys. If that fast string-key clause does not match, `JSONCodec` falls back to the full generic decoder, including atom-key lookup and detailed missing-field handling.

Use `codec/2` for exceptions and special behavior:

```elixir
codec :not_found, as: "not_found"
codec :variable_names, atom: :unsafe
codec :created_at, as: "createdAtMs", cast: :from_milliseconds
codec :name, transform: :trim_name
```

Field processing order is:

```text
JSON key mapping -> raw value -> cast -> type decode -> transform -> struct field
```

Use `cast:` to convert a wire representation into the declared Elixir type before type decoding:

```elixir
defmodule JobPayload do
  use JSONCodec, case: :camel, fast_path: :json

  defstruct [:id, :created_at]

  @type t :: %__MODULE__{id: String.t(), created_at: DateTime.t()}

  codec :created_at, as: "createdAtMs", cast: :from_milliseconds

  def from_milliseconds(milliseconds), do: DateTime.from_unix!(milliseconds, :millisecond)
end
```

Use `transform:` to normalize a value after it has decoded as the declared type:

```elixir
codec :name, transform: :trim_name

def trim_name(name), do: String.trim(name)
```

Local callback atoms are expanded to functions in the same module:

```elixir
codec :created_at, cast: :from_milliseconds
# calls from_milliseconds(value)

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

Use `strict: true` when `from_map/1` should accept only JSON/string-keyed maps and reject atom-key fallback:

```elixir
defmodule StrictPayload do
  use JSONCodec, case: :camel, strict: true, fast_path: :json

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

Atom policy is explicit:

```elixir
codec :status, atom: :existing
codec :variable_name, atom: :unsafe
```

`:unsafe` uses `String.to_atom/1`; only use it for bounded/trusted internal data.

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
- `[type]`
- `%{String.t() => value_type}`
- another `JSONCodec` module via `Other.t()`

## Schema export

Each codec module exports a JSON Schema-compatible map:

```elixir
FunctionID.schema()
JSONCodec.schema(FunctionID)
```

`json_schema/0` and `JSONCodec.json_schema/1` are also available as explicit aliases.

This is intentionally compatible with the direction of `JSONSpec`: codecs are the fast construction layer; schema validation can remain a separate layer.

## Benchmarks

Run:

```sh
MIX_ENV=dev mix run bench/program_facts_like.exs
```

Machine used for this snapshot: Apple M5, Elixir 1.20, Erlang/OTP 29. Payload: `142 KB`, 250 nested `data_flow` records.

| Case | ips | avg | memory |
|---|---:|---:|---:|
| `JSONCodec` map→struct | 4119.81 | 0.24 ms | 0.35 MB |
| handwritten map→struct | 4009.64 | 0.25 ms | 0.25 MB |
| `Jason.decode` only | 1378.28 | 0.73 ms | 1.10 MB |
| `Spectral` pre-decoded | 1252.96 | 0.80 ms | 3.23 MB |
| handwritten `Jason`+struct | 980.43 | 1.02 ms | 1.34 MB |
| `JSONCodec` `Jason`+struct | 972.52 | 1.03 ms | 1.45 MB |
| `Spectral` native JSON | 654.31 | 1.53 ms | 4.06 MB |

Interpretation:

- With `fast_path: :json`, `JSONCodec` is roughly tied with this handwritten decoder on decoded JSON maps, while still providing a generic fallback path.
- End-to-end, JSON parsing dominates. `JSONCodec.decode!/1` is within ~1.01× of handwritten `Jason`+struct and ~1.49× faster than `Spectral` native JSON on this shape.
- On map-heavy Iconify-like data (`mix run bench/iconify_like.exs`), `values_source:` avoids recomputing inherited defaults for every map entry. For advanced map-heavy decoders, `decode_values:` can return the final decoded map value directly when a custom decoder is clearer or faster than transforming a raw map and then invoking the generated nested decoder; in the Iconify-like benchmark this brings `JSONCodec` close to handwritten allocation.
- The goal is not to beat perfect handwritten code on every shape immediately; it is to make the generated path close enough that hand-written decoders disappear.

## Installation

```elixir
{:json_codec, "~> 0.1.1"}
```

## Development

See [CHANGELOG.md](CHANGELOG.md) for release notes.

This project was bootstrapped with VibeKit conventions.

```sh
mix deps.get
mix test
mix ci
```
