"""wb-onprem: maintenance utility for a Wiren Board on-premise installation."""

import pathlib

try:
    from ._version import __version__
except ImportError:
    # Run from a clone: cli/wb_onprem/ sits two levels below the repository root.
    try:
        __version__ = (pathlib.Path(__file__).resolve().parents[2] / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        __version__ = "unknown"
