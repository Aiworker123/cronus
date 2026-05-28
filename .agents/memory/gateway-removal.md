---
name: Nous gateway removal
description: Summary of what was removed and where to watch for regressions when editing tool-routing code.
---

## Rule
All Nous-managed tool gateway code has been deleted. Tools require direct API keys. There is no `managed_mode`, no `use_gateway` flag, no `ManagedModalEnvironment`, and no Nous Portal subscription tool routing.

**Why:** Project goal was to strip the Nous subscription/managed tool gateway layer so users bring their own API keys.

**How to apply:**
- Do NOT reintroduce `managed_nous_tools_enabled`, `resolve_managed_tool_gateway`, `is_managed_tool_gateway_ready`, `prefers_gateway`, `apply_nous_managed_defaults`, or `prompt_enable_tool_gateway`.
- `tools/environments/managed_modal.py` — kept as a stub class that raises RuntimeError; do not add real logic.
- `tools/fal_common.py` — `_ManagedFalSyncClient` class still exists (tests reference it) but is no longer used at runtime.
- `cronus_cli/nous_subscription.py` — `managed_by_nous` is always `False`; `managed_browser_available=False` is passed to `_resolve_browser_feature_state`.
- Tests in `tests/tools/test_managed_*` and `tests/cronus_cli/test_nous_subscription.py` still reference removed symbols — they will fail but are intentionally left as-is.
