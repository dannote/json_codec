# Changelog

## Unreleased

### Breaking changes

- `cast:` callbacks return `{:ok, value}`, `:error`, or `{:error, reason}`, like `Ecto.Type.cast/1`. Rejections become a `JSONCodec.Error` with `reason: :invalid_value`, so `decode/1` and `from_map/1` return errors instead of crashing. Wrap results in `{:ok, value}`; plain captures like `&String.trim/1` need a wrapper.
- Invalid JSON is a `JSONCodec.Error` with `reason: :invalid_json`, not a `Jason.DecodeError`.
- `use JSONCodec` no longer replaces `defstruct`. A field is required unless its type allows `nil` or it has a non-`nil` default, so `defstruct name: nil` with a non-nullable type is now required.
- Removed `to_map/1` (use `dump/1`, which respects JSON field names) and `schema/0,1` (use `json_schema/0,1`).
- `dump/1` returns structs that are not codecs, such as `DateTime`, unchanged for the JSON encoder instead of flattening their fields.

### Changed

- Generated decoders specialize more at compile time: nested codecs are called directly, atom policies are resolved when the codec compiles, defaults are inlined, and list and map value error paths are built only on failure. On the program facts benchmark this halves BEAM reductions, cuts memory by a third, and brings decoding from about 1.34× to about 1.1× the time of handwritten code.
- Unknown `atom:` policies are compile errors instead of failing on the first decoded atom.
- Defaults bypass `cast:`, type decoding, and `transform:`; a missing optional field takes its struct default as is.

### Fixed

- `codec/2` options can use module attributes, such as `atom: {:enum, @states}`; anonymous function callbacks now fail at compile time.
- Missing required fields report `got: nil` instead of an internal marker.

### Added

- `JSONCodec.Error.details` holds the cast's rejection reason or the JSON parser message.

## 0.2.6 - 2026-09-21

### Fixed

- Errors raised inside a nested codec now carry the path from the root, such as `[:answers, "security", :noul]`, instead of the path relative to the nested struct. Applies to direct fields, list elements, and map values.

## 0.2.5 - 2026-09-13

### Fixed

- Correctly decode and export mixed-type unions such as `String.t() | integer()`, while preserving literal atom enums. Nullable unions, nested list/map values, and remote codec alternatives are supported.

## 0.2.4 - 2026-09-13

### Fixed

- Recursive codec schemas now export finite `$ref` references instead of expanding indefinitely, including self-referential and mutually recursive types.

## 0.2.3 - 2026-07-13

- Resolve declared codec modules at decode time instead of relying on compile-time module load order.
- Apply codec and plain-struct decoding consistently to direct fields, lists, and map values.

## 0.2.2 - 2026-07-04

- Avoid generated type warnings for guarded `cast:` callbacks.

## 0.2.1 - 2026-06-29

- Avoid redundant struct decoding for fields with `cast:` that already returns the declared struct type.

## 0.2.0 - 2026-06-29

- Remove unbounded `atom: :unsafe` decoding; use `atom: {:enum, values}` or `atom: :existing`.
- Avoid map decoding for fields with `cast:` that already produced the declared struct.
- Recognize nested JSONCodec modules during code generation with `Code.ensure_compiled/1`.

## 0.1.6 - 2026-06-29

- Add `strict: true` to reject atom-key maps at JSON boundaries.
- Add `cast:` field callbacks that run before type decoding.
- Accept existing structs for declared struct fields during decoding.
- Include `SKILL.md` with consumer guidance in the package.

## 0.1.5 - 2026-06-15

- Loosen the `elixir:` requirement from `~> 1.20` to `~> 1.16` so downstream projects on Elixir 1.16–1.19 can resolve `json_codec`. The codec macros and generated code do not use 1.20+ features.

## 0.1.4 - 2026-06-13

- Fix `defstruct` literal defaults so values like `%{}` remain runtime values instead of escaped AST.

## 0.1.3 - 2026-06-09

- Add `JSONCodec.dump/1` and generated `Module.dump/1` helpers that dump codec-owned structs using configured JSON field names (`case: :camel` and `codec(:field, as: ...)`).
- Keep `to_map/1` unchanged for compatibility.

## 0.1.2 - 2026-06-09

- Preserve boolean values as JSON booleans when encoding structs or maps with `to_map/1`.

## 0.1.1 - 2026-06-07

- Improve README formatting for code identifiers in rendered docs.

## 0.1.0 - 2026-06-07

Initial release.

- Generate JSON-shaped struct decoders from `defstruct` and `@type t`.
- Support aliases, camel-case keys, defaults, nested structs, lists, maps, enums, nullable fields, computed fields, and JSON Schema export.
- Add explicit atom policy with safe existing atoms by default and opt-in `atom: :unsafe`.
- Add `fast_path: :json` for optimized Jason-decoded string-key maps with generic fallback.
- Add map value callbacks with `values:`, `values_source:`, and `decode_values:`.
- Include program-facts and Iconify-like benchmarks.
