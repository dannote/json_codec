---
name: json-codec-consumer
description: Use JSONCodec correctly in Elixir projects when decoding JSON-shaped maps/strings into structs at HTTP, config, file, event, provider, CLI, or protocol boundaries. Prefer this over Jason.decode! + hand-written map parsing.
---

# JSONCodec Consumer Rules

Use this skill whenever code decodes JSON or JSON-shaped maps into Elixir data.

Common examples:

- HTTP API responses
- HTTP request bodies
- config files
- cached JSON files
- event payloads
- webhook payloads
- provider protocol payloads
- CLI tool JSON output
- JWT or envelope payloads

## Core rule

Do **not** hand-roll JSON boundary parsing with:

```elixir
Jason.decode!(json)
Map.get(map, "field")
%{field: map["field"]}
```

Instead:

1. Define a boundary struct that mirrors the JSON shape.
2. Decode with `JSONCodec`.
3. Convert once into a separate domain struct only when the internal concept differs from the wire shape.

## Basic boundary struct

External JSON:

```json
{"name":"demo","item_count":3,"enabled":true}
```

Boundary struct:

```elixir
defmodule ImportSummary do
  use JSONCodec, strict: true, fast_path: :json

  defstruct [:name, :item_count, :enabled]

  @type t :: %__MODULE__{
          name: String.t(),
          item_count: non_neg_integer(),
          enabled: boolean()
        }
end
```

Decode JSON string:

```elixir
ImportSummary.decode(json)
```

Decode already-decoded JSON map:

```elixir
ImportSummary.from_map(map)
```

## Use built-in case conversion

If JSON uses camelCase and Elixir uses snake_case, use JSONCodec's built-in casing:

```elixir
defmodule JobEvent do
  use JSONCodec, case: :camel, strict: true, fast_path: :json

  defstruct [:job_id, :queued_at, :retry_count]

  @type t :: %__MODULE__{
          job_id: String.t(),
          queued_at: String.t(),
          retry_count: non_neg_integer()
        }
end
```

This maps automatically:

```text
job_id      <-> "jobId"
queued_at   <-> "queuedAt"
retry_count <-> "retryCount"
```

Do **not** write redundant aliases for ordinary casing:

```elixir
codec(:job_id, as: "jobId") # unnecessary with case: :camel
```

Use `codec(:field, as: ...)` only for field names that cannot be derived by case conversion:

```elixir
defmodule ClaimsEnvelope do
  use JSONCodec, strict: true, fast_path: :json

  defstruct [:standard_claims, :custom_claims]

  @type t :: %__MODULE__{
          standard_claims: map() | nil,
          custom_claims: map() | nil
        }

  codec(:custom_claims, as: "https://example.com/custom_claims")
end
```

## Cast wire values before type decode

Use `cast:` when JSON sends one representation but the struct field should have another declared Elixir type.

External JSON:

```json
{"id":"job-1","createdAtMs":1782703591000}
```

Boundary struct:

```elixir
defmodule JobPayload do
  use JSONCodec, case: :camel, strict: true, fast_path: :json

  defstruct [:id, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t()
        }

  codec :created_at, as: "createdAtMs", cast: :from_milliseconds

  def from_milliseconds(milliseconds), do: DateTime.from_unix!(milliseconds, :millisecond)
end
```

Callback forms:

```elixir
codec :created_at, cast: :from_milliseconds
codec :created_at, cast: &MyCasts.from_milliseconds/1
```

## Processing order

Field processing order is:

```text
key mapping -> raw value -> cast -> type decode -> transform -> struct
```

- `case:` / `as:` maps JSON keys to struct fields.
- `cast:` converts raw wire values before type decoding.
- `transform:` normalizes already-decoded values.

Example transform:

```elixir
defmodule UserPayload do
  use JSONCodec, strict: true, fast_path: :json

  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  codec(:name, transform: :trim_name)

  def trim_name(name), do: String.trim(name)
end
```

Do not use `transform:` when the raw JSON value is not already decodable as the declared field type. Use `cast:` instead.

## Strict JSON maps

`JSONCodec.from_map/1` normally supports generic map decoding. If the input is supposed to be decoded JSON from an external boundary, use `strict: true`:

```elixir
use JSONCodec, strict: true, fast_path: :json
```

This rejects atom-key maps and prevents loose mixed atom/string boundary contracts.

## Error handling

Keep JSONCodec errors structured:

```elixir
case JobPayload.decode(json) do
  {:ok, payload} -> {:ok, payload}
  {:error, reason} -> {:error, {:invalid_job_payload, reason}}
end
```

Avoid converting codec errors into vague strings too early.

## Nested objects and maps

Use nested JSONCodec structs instead of manual recursive parsing:

```elixir
defmodule PackageFile do
  use JSONCodec, strict: true, fast_path: :json

  defstruct [:path, :bytes]

  @type t :: %__MODULE__{path: String.t(), bytes: non_neg_integer()}
end

defmodule PackageManifest do
  use JSONCodec, case: :camel, strict: true, fast_path: :json

  defstruct [:name, files: []]

  @type t :: %__MODULE__{
          name: String.t(),
          files: [PackageFile.t()]
        }
end
```

For maps with structured values, use typed map fields:

```elixir
defmodule Catalog do
  use JSONCodec, strict: true, fast_path: :json

  defstruct entries: %{}

  @type t :: %__MODULE__{entries: %{String.t() => PackageFile.t()}}
end
```

Map-field callbacks:

- `values:` transforms each raw map value before nested decode.
- `decode_values:` returns the final map value and bypasses nested decode.
- `values_source:` computes shared callback context once per map field.

## Do not

- Do not use `Jason.decode!` followed by ad hoc `Map.get` chains.
- Do not support mixed atom/string keys at external JSON boundaries.
- Do not write redundant `as:` mappings for normal camelCase/snake_case conversion.
- Do not use `transform:` for wire-type conversion; use `cast:`.
- Do not use `String.to_atom/1` for JSON values unless the field explicitly declares `codec(..., atom: :unsafe)` and the vocabulary is trusted.
- Do not hide JSONCodec errors behind generic `:invalid` or string errors at the boundary.

## Quick checklist

Before writing JSON parsing code, verify:

- [ ] There is a `defstruct` with `use JSONCodec` for the external JSON shape.
- [ ] External JSON boundaries use `strict: true`.
- [ ] CamelCase fields use `case: :camel`.
- [ ] `as:` is only used for non-case-convertible field names.
- [ ] Wire-to-Elixir value conversions use `cast:`.
- [ ] Same-type normalization uses `transform:`.
- [ ] Errors preserve JSONCodec details.
