# Schema ownership

- `source/` is the sole editable source for product Rime schemas and
  dictionaries.
- `test/` contains isolated deterministic fixtures. Test dictionaries disable
  user learning and must never be packaged as product data.
- `generated/` is reserved for build output and is ignored by Git.

Platform builds may read `source/` directly or copy it into their own build
directories. A copied file is generated output and must not become a second
editing surface.
