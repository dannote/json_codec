# Changelog

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
