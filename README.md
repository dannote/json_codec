# JSONCodec

Compile-time generated codecs for JSON-shaped Elixir structs.

`JSONCodec` is **not** another JSON parser. It uses [`Jason`](https://hex.pm/packages/jason) for parsing and focuses on the annoying part that tends to be rewritten in every Elixir project: converting decoded string-keyed JSON maps into nested structs with aliases, defaults, computed fields, explicit atom policy, and schema export.

```elixir
defmodule FunctionID do
  use JSONCodec

  field :module, :string
  field :function, :string
  field :arity, :non_neg_integer

  computed :id, fn function ->
    "#{function.module}.#{function.function}/#{function.arity}"
  end
end

defmodule DataRef do
  use JSONCodec

  field :type, {:enum, [:argument, :return, :variable]}
  field :function, FunctionID
  field :name, :atom, optional: true, atom: :unsafe
  field :index, :non_neg_integer, optional: true
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

`JSONCodec` generates that boring code from a small DSL.

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

## Field options

```elixir
field :name, :string
field :version, :string, optional: true
field :dev_dependencies, {:map, :string, :string}, json: "devDependencies", default: %{}
field :branch, {:nullable, {:enum, [:then, :else, :case]}}, default: nil
field :variable_names, {:list, :atom}, default: [], atom: :unsafe
```

Supported MVP types:

- `:string`
- `:integer`
- `:non_neg_integer`
- `:pos_integer`
- `:float`
- `:number`
- `:boolean`
- `:atom`
- `:any` / `:term`
- `{:nullable, type}`
- `{:literal, value}`
- `{:enum, atoms}`
- `{:list, type}`
- `{:map, key_type, value_type}`
- another `JSONCodec` module

Atom policy is explicit:

```elixir
field :status, {:enum, [:active, :inactive]}
field :name, :atom, atom: :existing
field :variable_name, :atom, atom: :unsafe
```

`:unsafe` uses `String.to_atom/1`; only use it for bounded/trusted internal data.

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
| handwritten map→struct | 3722.88 | 0.27 ms | 0.25 MB |
| JSONCodec map→struct | 1891.19 | 0.53 ms | 0.43 MB |
| Jason.decode only | 1280.19 | 0.78 ms | 1.10 MB |
| handwritten Jason+struct | 918.12 | 1.09 ms | 1.34 MB |
| Spectral pre-decoded | 882.38 | 1.13 ms | 3.23 MB |
| JSONCodec Jason+struct | 717.41 | 1.39 ms | 1.53 MB |
| Spectral native JSON | 596.49 | 1.68 ms | 4.06 MB |

Interpretation:

- `JSONCodec` is about 2× slower than this handwritten decoder on decoded maps, but still much faster and lower allocation than validation/type-walking approaches.
- End-to-end, JSON parsing dominates. `JSONCodec.decode!/1` is ~1.3× slower than handwritten Jason+struct in this MVP and ~1.2× faster than Spectral native JSON on this shape.
- The goal is not to beat perfect handwritten code immediately; it is to make the generated path close enough that hand-written decoders disappear.

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
