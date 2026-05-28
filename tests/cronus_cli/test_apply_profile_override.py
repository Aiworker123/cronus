"""Regression tests for _apply_profile_override CRONUS_HOME guard (issue #22502).

When CRONUS_HOME is set to the cronus root (e.g. systemd hardcodes
CRONUS_HOME=/root/.cronus), _apply_profile_override must still read
active_profile and update CRONUS_HOME to the profile directory.

When CRONUS_HOME is already a profile directory (.../profiles/<name>),
_apply_profile_override must trust it and return without re-reading
active_profile (child-process inheritance contract).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest


def _run_apply_profile_override(
    tmp_path, monkeypatch, *, cronus_home: str | None, active_profile: str | None,
    argv: list[str] | None = None,
):
    """Run _apply_profile_override in isolation.

    Returns the value of os.environ["CRONUS_HOME"] after the call,
    or None if unset.
    """
    cronus_root = tmp_path / ".cronus"
    cronus_root.mkdir(parents=True, exist_ok=True)

    if active_profile is not None:
        (cronus_root / "active_profile").write_text(active_profile)

    if active_profile and active_profile != "default":
        (cronus_root / "profiles" / active_profile).mkdir(parents=True, exist_ok=True)

    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    if cronus_home is not None:
        monkeypatch.setenv("CRONUS_HOME", cronus_home)
    else:
        monkeypatch.delenv("CRONUS_HOME", raising=False)

    monkeypatch.setattr(sys, "argv", argv or ["cronus", "gateway", "start"])

    from cronus_cli.main import _apply_profile_override
    _apply_profile_override()

    return os.environ.get("CRONUS_HOME")


class TestApplyProfileOverrideCronusHomeGuard:
    """Regression guard for issue #22502.

    Verifies that CRONUS_HOME pointing to the cronus root does NOT suppress
    the active_profile check, while CRONUS_HOME already pointing to a
    profile directory IS trusted as-is.
    """

    def test_cronus_home_at_root_with_active_profile_is_redirected(
        self, tmp_path, monkeypatch
    ):
        """CRONUS_HOME=/root/.cronus + active_profile=coder must redirect
        CRONUS_HOME to .../profiles/coder.

        Bug scenario from #22502: systemd sets CRONUS_HOME to the cronus root
        and the user switches to a profile via `cronus profile use`.
        Before the fix, the guard returned early and active_profile was ignored.
        """
        cronus_root = tmp_path / ".cronus"
        cronus_root.mkdir(parents=True, exist_ok=True)

        result = _run_apply_profile_override(
            tmp_path,
            monkeypatch,
            cronus_home=str(cronus_root),
            active_profile="coder",
        )

        assert result is not None, "CRONUS_HOME must be set after profile redirect"
        assert "profiles" in result, (
            f"Expected CRONUS_HOME to point into profiles/ dir, got: {result!r}"
        )
        assert result.endswith("coder"), (
            f"Expected CRONUS_HOME to end with 'coder', got: {result!r}"
        )

    def test_cronus_home_already_profile_dir_is_trusted(self, tmp_path, monkeypatch):
        """CRONUS_HOME=.../profiles/coder must not be overridden even when
        active_profile says something different.

        Preserves the child-process inheritance contract: a subprocess spawned
        with CRONUS_HOME already set to a specific profile must stay in that
        profile.
        """
        cronus_root = tmp_path / ".cronus"
        profile_dir = cronus_root / "profiles" / "coder"
        profile_dir.mkdir(parents=True, exist_ok=True)

        (cronus_root / "active_profile").write_text("other")

        monkeypatch.setattr(Path, "home", lambda: tmp_path)
        monkeypatch.setenv("CRONUS_HOME", str(profile_dir))
        monkeypatch.setattr(sys, "argv", ["cronus", "gateway", "start"])

        from cronus_cli.main import _apply_profile_override
        _apply_profile_override()

        assert os.environ.get("CRONUS_HOME") == str(profile_dir), (
            "CRONUS_HOME must remain unchanged when already pointing to a profile dir"
        )

    def test_cronus_home_unset_reads_active_profile(self, tmp_path, monkeypatch):
        """Classic case: CRONUS_HOME unset + active_profile=coder must set
        CRONUS_HOME to the profile directory (existing behaviour must not regress).
        """
        result = _run_apply_profile_override(
            tmp_path,
            monkeypatch,
            cronus_home=None,
            active_profile="coder",
        )

        assert result is not None
        assert "coder" in result

    def test_cronus_home_unset_default_profile_no_redirect(self, tmp_path, monkeypatch):
        """active_profile=default must not redirect CRONUS_HOME."""
        cronus_root = tmp_path / ".cronus"
        cronus_root.mkdir(parents=True, exist_ok=True)

        monkeypatch.setattr(Path, "home", lambda: tmp_path)
        monkeypatch.delenv("CRONUS_HOME", raising=False)
        monkeypatch.setattr(sys, "argv", ["cronus", "gateway", "start"])
        (cronus_root / "active_profile").write_text("default")

        from cronus_cli.main import _apply_profile_override
        _apply_profile_override()

        assert os.environ.get("CRONUS_HOME") is None
