# Shared engine boundary

This directory is reserved for the InkFlow-owned C ABI and its librime-backed
implementation. Platform targets must depend on that ABI rather than including
librime headers directly.

The engine is intentionally absent from the foundation task. A production
target must fail when librime is unavailable; test doubles belong only in test
targets.
