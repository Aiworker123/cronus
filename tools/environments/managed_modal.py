"""Managed Modal environment — no longer supported."""

from __future__ import annotations


class ManagedModalEnvironment:
    """Stub: Managed Modal via Nous gateway is no longer supported.

    Users must provide their own Modal credentials
    (MODAL_TOKEN_ID + MODAL_TOKEN_SECRET or ``modal setup``).
    """

    def __init__(self, *args, **kwargs):
        raise RuntimeError(
            "Managed Modal is no longer supported. "
            "Set MODAL_TOKEN_ID and MODAL_TOKEN_SECRET, or run `modal setup`, "
            "and use TERMINAL_MODAL_MODE=direct."
        )

    def execute(self, *args, **kwargs):
        raise RuntimeError("Managed Modal is no longer supported.")

    def cleanup(self):
        pass
