# Changelog

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
