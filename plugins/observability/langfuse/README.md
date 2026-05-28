# Langfuse Observability Plugin

This plugin ships bundled with Cronus but is **opt-in** — it only loads when
you explicitly enable it.

## Enable

```bash
pip install langfuse
cronus plugins enable observability/langfuse
```

Or check the box in the interactive `cronus plugins` UI.

## Required credentials

Set these in `~/.cronus/.env`:

```bash
CRONUS_LANGFUSE_PUBLIC_KEY=pk-lf-...
CRONUS_LANGFUSE_SECRET_KEY=sk-lf-...
CRONUS_LANGFUSE_BASE_URL=https://cloud.langfuse.com   # or your self-hosted URL
```

Without the SDK or credentials the hooks no-op silently — the plugin fails
open.

## Verify

```bash
cronus plugins list                 # observability/langfuse should show "enabled"
cronus chat -q "hello"              # then check Langfuse for a "Cronus turn" trace
```

## Optional tuning

```bash
CRONUS_LANGFUSE_ENV=production       # environment tag
CRONUS_LANGFUSE_RELEASE=v1.0.0       # release tag
CRONUS_LANGFUSE_SAMPLE_RATE=0.5      # sample 50% of traces
CRONUS_LANGFUSE_MAX_CHARS=12000      # max chars per field (default: 12000)
CRONUS_LANGFUSE_DEBUG=true           # verbose plugin logging
```

## Disable

```bash
cronus plugins disable observability/langfuse
```
