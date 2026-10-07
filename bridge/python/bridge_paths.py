"""Where the bridge lives on this machine. Nothing is hard-coded: every user
has their own drives and terminal folders.

Order for every key: environment variable -> bridge/paths.json -> paths.json
one folder up -> default / auto-detect. Template: bridge/paths.example.json.

    terminal       BRIDGE_TERMINAL       terminal64.exe that runs BridgeEA
    terminal_data  BRIDGE_TERMINAL_DATA  its data folder (found by origin.txt)
    common_files   BRIDGE_COMMON_FILES   ...\\MetaQuotes\\Terminal\\Common\\Files
"""
import json
import os
from functools import lru_cache
from pathlib import Path

BRIDGE_FOLDER = Path(__file__).resolve().parent.parent
APPDATA_TERMINALS = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal"
DEFAULT_TERMINAL = r"C:\Program Files\MetaTrader 5\terminal64.exe"


@lru_cache(maxsize=None)
def _config():
    for candidate in (BRIDGE_FOLDER / "paths.json", BRIDGE_FOLDER.parent / "paths.json"):
        if candidate.exists():
            return json.loads(candidate.read_text(encoding="utf-8"))
    return {}


def _value(key, env):
    return os.environ.get(env) or _config().get(key) or None


def terminal():
    return Path(_value("terminal", "BRIDGE_TERMINAL") or DEFAULT_TERMINAL)


def terminal_data():
    """Data folder of the terminal (contains MQL5\\); None if not found."""
    value = _value("terminal_data", "BRIDGE_TERMINAL_DATA")
    if value:
        return Path(value)
    install = str(terminal().parent).rstrip("\\").lower()
    for folder in APPDATA_TERMINALS.glob("*"):
        origin = folder / "origin.txt"
        if origin.exists() and origin.read_text(encoding="utf-16").strip().rstrip("\\").lower() == install:
            return folder
    return None


def common_files():
    value = _value("common_files", "BRIDGE_COMMON_FILES")
    return Path(value) if value else APPDATA_TERMINALS / "Common" / "Files"
