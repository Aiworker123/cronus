"""Resolve CRONUS_HOME for standalone skill scripts.

Skill scripts may run outside the Cronus process (e.g. system Python,
nix env, CI) where ``cronus_constants`` is not importable.  This module
provides the same ``get_cronus_home()`` and ``display_cronus_home()``
contracts as ``cronus_constants`` without requiring it on ``sys.path``.

When ``cronus_constants`` IS available it is used directly so that any
future enhancements (profile resolution, Docker detection, etc.) are
picked up automatically.  The fallback path replicates the core logic
from ``cronus_constants.py`` using only the stdlib.

All scripts under ``google-workspace/scripts/`` should import from here
instead of duplicating the ``CRONUS_HOME = Path(os.getenv(...))`` pattern.
"""

from __future__ import annotations

import os
from pathlib import Path

try:
    from cronus_constants import display_cronus_home as display_cronus_home
    from cronus_constants import get_cronus_home as get_cronus_home
except (ModuleNotFoundError, ImportError):

    def get_cronus_home() -> Path:
        """Return the Cronus home directory (default: ~/.cronus).

        Mirrors ``cronus_constants.get_cronus_home()``."""
        val = os.environ.get("CRONUS_HOME", "").strip()
        return Path(val) if val else Path.home() / ".cronus"

    def display_cronus_home() -> str:
        """Return a user-friendly ``~/``-shortened display string.

        Mirrors ``cronus_constants.display_cronus_home()``."""
        home = get_cronus_home()
        try:
            return "~/" + str(home.relative_to(Path.home()))
        except ValueError:
            return str(home)
