"""PTY bridge for `cronus dashboard` chat tab.

Wraps a child process behind a pseudo-terminal so its ANSI output can be
streamed to a browser-side terminal emulator (xterm.js) and typed
keystrokes can be fed back in.  The only caller today is the
``/api/pty`` WebSocket endpoint in ``cronus_cli.web_server``.

Design constraints:

* **Cross-platform.**  POSIX systems (Linux, macOS) use ``ptyprocess``
  (via ``fcntl`` / ``termios``).  Native Windows 10 build 17763+ uses
  ``pywinpty`` which drives the Windows ConPTY API — no WSL required.
* **Zero Node dependency on the server side.**  The browser talks to the
  same ``cronus --tui`` binary it would launch from the CLI, so every TUI
  feature (slash popover, model picker, tool rows, markdown, skin engine,
  clarify/sudo/approval prompts) ships automatically on both platforms.
* **Byte-safe I/O.**  Reads and writes are always ``bytes`` at the bridge
  boundary.  pywinpty 2.x returns ``str`` internally; the Windows backend
  re-encodes to UTF-8 bytes before returning.  UTF-8 boundaries may land
  mid-read; the browser-side xterm.js handles split sequences correctly.
"""

from __future__ import annotations

import os
import sys
import time
from typing import Optional, Sequence

__all__ = ["PtyBridge", "PtyUnavailableError"]


class PtyUnavailableError(RuntimeError):
    """Raised when a PTY cannot be created on this platform.

    On native Windows this happens when ``pywinpty`` is not installed or
    the Windows build is older than 17763 (ConPTY requires 10 build 17763+).
    On POSIX it means ``ptyprocess`` is missing.  The dashboard surfaces
    the message to the user as a chat-tab banner.
    """


# ---------------------------------------------------------------------------
# Backend detection — POSIX uses ptyprocess; Windows uses pywinpty (ConPTY)
# ---------------------------------------------------------------------------

_IS_WINDOWS = sys.platform.startswith("win")
_PTY_AVAILABLE = False
_BACKEND: Optional[str] = None  # "posix" | "windows"

if _IS_WINDOWS:
    try:
        import winpty as _winpty  # type: ignore  # provided by the pywinpty package
        _PTY_AVAILABLE = True
        _BACKEND = "windows"
    except ImportError:
        _winpty = None  # type: ignore
else:
    # POSIX — import ptyprocess only; fcntl/termios/select are deferred to
    # the methods that actually use them so this module imports cleanly on any
    # platform even in edge-case dev setups.
    try:
        import ptyprocess as _ptyprocess  # type: ignore
        _PTY_AVAILABLE = True
        _BACKEND = "posix"
    except ImportError:
        _ptyprocess = None  # type: ignore


class PtyBridge:
    """Cross-platform pseudo-terminal bridge for byte streaming.

    Not thread-safe.  A single bridge is owned by the WebSocket handler
    that spawned it; the reader runs in an executor thread while writes
    happen on the event-loop thread.  Both sides are safe because the
    underlying PTY (kernel on POSIX, ConPTY on Windows) is the actual
    synchronisation point.
    """

    def __init__(self, proc: object, *, backend: str) -> None:
        self._proc = proc
        self._backend = backend
        self._closed = False
        # POSIX only: cache the raw fd so read/write skip method-call overhead.
        if backend == "posix":
            self._fd: int = proc.fd  # type: ignore[union-attr]
        else:
            self._fd = -1

    # -- lifecycle --------------------------------------------------------

    @classmethod
    def is_available(cls) -> bool:
        """True if a PTY can be spawned on this platform."""
        return bool(_PTY_AVAILABLE)

    @classmethod
    def spawn(
        cls,
        argv: Sequence[str],
        *,
        cwd: Optional[str] = None,
        env: Optional[dict] = None,
        cols: int = 80,
        rows: int = 24,
    ) -> "PtyBridge":
        """Spawn ``argv`` behind a new PTY and return a bridge.

        Raises :class:`PtyUnavailableError` when no PTY backend is available
        (missing package or unsupported platform).  Raises
        :class:`FileNotFoundError` or :class:`OSError` for ordinary exec
        failures (missing binary, bad cwd, etc.).
        """
        if not _PTY_AVAILABLE:
            if _IS_WINDOWS:
                raise PtyUnavailableError(
                    "The `pywinpty` package is missing. "
                    "Install with: pip install pywinpty "
                    "(or: pip install -e '.[pty]')."
                )
            raise PtyUnavailableError(
                "The `ptyprocess` package is missing. "
                "Install with: pip install ptyprocess "
                "(or: pip install -e '.[pty]')."
            )

        # PTY-hosted programs expect TERM to describe the terminal type.
        # CI often runs without TERM in the parent, which breaks tput probes
        # before winsize reads.  Preserve explicit caller overrides but
        # backfill a sensible default when TERM is missing or blank.
        spawn_env = (os.environ.copy() if env is None else env.copy())
        if not spawn_env.get("TERM"):
            spawn_env["TERM"] = "xterm-256color"

        if _BACKEND == "windows":
            proc = _winpty.PtyProcess.spawn(  # type: ignore[union-attr]
                list(argv),
                cwd=cwd,
                env=spawn_env,
                dimensions=(rows, cols),
            )
            return cls(proc, backend="windows")
        else:
            proc = _ptyprocess.PtyProcess.spawn(  # type: ignore[union-attr]
                list(argv),
                cwd=cwd,
                env=spawn_env,
                dimensions=(rows, cols),
            )
            return cls(proc, backend="posix")

    @property
    def pid(self) -> int:
        return int(self._proc.pid)  # type: ignore[union-attr]

    def is_alive(self) -> bool:
        if self._closed:
            return False
        try:
            return bool(self._proc.isalive())  # type: ignore[union-attr]
        except Exception:
            return False

    # -- I/O --------------------------------------------------------------

    def read(self, timeout: float = 0.2) -> Optional[bytes]:
        """Read up to 64 KiB of raw bytes from the PTY.

        Returns:
            * ``bytes`` — child output (possibly empty if no data arrived)
            * ``b""`` — no data available within ``timeout``
            * ``None`` — child has exited and the PTY is at EOF

        Never blocks longer than ``timeout`` seconds.  Safe to call after
        :meth:`close`; returns ``None`` in that case.
        """
        if self._closed:
            return None
        if _BACKEND == "windows":
            return self._read_windows(timeout)
        return self._read_posix(timeout)

    def _read_windows(self, timeout: float) -> Optional[bytes]:
        """Windows ConPTY read via pywinpty.

        pywinpty 2.x ``read()`` takes a timeout in **milliseconds** and
        returns ``str``.  We encode to UTF-8 bytes so callers always see
        the same ``bytes | None`` contract as the POSIX backend.
        """
        try:
            data = self._proc.read(65536, timeout=int(timeout * 1000))  # type: ignore[union-attr]
        except EOFError:
            return None
        except Exception:
            if not self.is_alive():
                return None
            return b""
        if data is None:
            return b""
        if isinstance(data, str):
            return data.encode("utf-8", errors="replace")
        return data if data else b""

    def _read_posix(self, timeout: float) -> Optional[bytes]:
        """POSIX PTY read via select + os.read on the master fd."""
        import errno
        import select
        try:
            readable, _, _ = select.select([self._fd], [], [], timeout)
        except (OSError, ValueError):
            return None
        if not readable:
            return b""
        try:
            data = os.read(self._fd, 65536)
        except OSError as exc:
            # EIO on Linux = slave side closed.  EBADF = already closed.
            if exc.errno in {errno.EIO, errno.EBADF}:
                return None
            raise
        if not data:
            return None
        return data

    def write(self, data: bytes) -> None:
        """Write raw bytes to the PTY master (i.e. the child's stdin)."""
        if self._closed or not data:
            return
        if _BACKEND == "windows":
            self._write_windows(data)
        else:
            self._write_posix(data)

    def _write_windows(self, data: bytes) -> None:
        """pywinpty 2.x accepts bytes or str on write()."""
        try:
            self._proc.write(data)  # type: ignore[union-attr]
        except Exception:
            pass

    def _write_posix(self, data: bytes) -> None:
        """Loop until all bytes are drained to the PTY master fd."""
        import errno
        view = memoryview(data)
        while view:
            try:
                n = os.write(self._fd, view)
            except OSError as exc:
                if exc.errno in {errno.EIO, errno.EBADF, errno.EPIPE}:
                    return
                raise
            if n <= 0:
                return
            view = view[n:]

    def resize(self, cols: int, rows: int) -> None:
        """Forward a terminal-resize to the child.

        On POSIX sends ``TIOCSWINSZ`` via the master fd; on Windows calls
        pywinpty's ``setwinsize(rows, cols)``.
        """
        if self._closed:
            return
        if _BACKEND == "windows":
            try:
                self._proc.setwinsize(max(1, rows), max(1, cols))  # type: ignore[union-attr]
            except Exception:
                pass
        else:
            import fcntl
            import struct
            import termios
            # struct winsize: rows, cols, xpixel, ypixel (all unsigned short)
            winsize = struct.pack("HHHH", max(1, rows), max(1, cols), 0, 0)
            try:
                fcntl.ioctl(self._fd, termios.TIOCSWINSZ, winsize)
            except OSError:
                pass

    # -- teardown ---------------------------------------------------------

    def close(self) -> None:
        """Terminate the child and release all resources.

        Idempotent.  On POSIX escalates SIGHUP → SIGTERM → SIGKILL with a
        0.5 s grace period between each.  On Windows calls pywinpty's
        ``close()`` which terminates the ConPTY session.
        """
        if self._closed:
            return
        self._closed = True
        if _BACKEND == "windows":
            self._close_windows()
        else:
            self._close_posix()

    def _close_windows(self) -> None:
        try:
            self._proc.close()  # type: ignore[union-attr]
        except Exception:
            pass

    def _close_posix(self) -> None:
        import signal
        # SIGHUP is the conventional "your terminal went away" signal.
        # We escalate if the child ignores it.
        # windows-footgun: ok — POSIX-only path (_BACKEND == "posix")
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
            if not self._proc.isalive():  # type: ignore[union-attr]
                break
            try:
                self._proc.kill(sig)  # type: ignore[union-attr]
            except Exception:
                pass
            deadline = time.monotonic() + 0.5
            while self._proc.isalive() and time.monotonic() < deadline:  # type: ignore[union-attr]
                time.sleep(0.02)
        try:
            self._proc.close(force=True)  # type: ignore[union-attr]
        except Exception:
            pass

    # Context-manager sugar — handy in tests and ad-hoc scripts.
    def __enter__(self) -> "PtyBridge":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()
