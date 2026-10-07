"""
Python side of the MQL5 bridge.

Builds a declarative indicator request, hands it to the BridgeEA expert
advisor through the terminal's Common\\Files\\Bridge folder and returns the
calculated buffers as a pandas DataFrame.

Protocol:
    request_{id}.json   written by Python, picked up by the EA
    response_{id}.csv   written by the EA once every buffer is ready

The EA deletes the request file in BOTH outcomes, and on success only after
the response has been renamed into place. Therefore:
    response exists AND request is gone  -> done
    request is gone AND no response      -> the EA failed (known instantly)
    request still there after timeout    -> the EA never picked it up

What this client adds over a plain "write JSON, wait for CSV" loop:
    - a failed request is detected the moment the EA drops it, instead of
      waiting out the whole timeout (it used to mean 30 minutes of silence
      per new symbol);
    - fetch_csv / run_pipeline retry with a FRESH request_id - the first
      request for a new symbol often fails while the terminal loads history,
      and that failed attempt is exactly what makes the next one succeed;
    - the EA journal lines of a failed request are attached to the error;
    - enum values and the timeframe are validated: the EA silently falls
      back to PERIOD_H1 / PRICE_CLOSE / MODE_SMA on an unknown string;
    - iCustom is rejected: it is in the reference table, not in the EA;
    - look-ahead buffers (Ichimoku chikou, negative shifts) print a warning.
"""

import json
import os
import re
import time
import uuid
from datetime import date, timedelta
from pathlib import Path

import pandas as pd

import bridge_paths

# --- Configuration -------------------------------------------------------
# Paths are never hard-coded: every user has their own drives (bridge_paths.py).
COMMON_FILES = bridge_paths.common_files() / "Bridge"
COMMON_FILES.mkdir(parents=True, exist_ok=True)

# The reference table is read by both sides of the bridge, so the copy in the
# exchange folder is the authoritative one. The local copy is a fallback for
# running the validator without a terminal.
ETALON_FILE = COMMON_FILES / "indicators_etalon.json"
if not ETALON_FILE.exists():
    ETALON_FILE = (Path(__file__).resolve().parent.parent
                   / "common_files/Bridge/indicators_etalon.json")

# Data folder of the terminal that runs BridgeEA. Only used to read its
# journal after a failure; None when it cannot be found.
TERMINAL_DATA = bridge_paths.terminal_data()

RESPONSE_TIMEOUT_SEC = 180
RETRIES = 3
POLL_INTERVAL_SEC = 0.2

# Exactly the strings BridgeEA.mq5 converts. Anything else is replaced by the
# EA's fallback without an error, so it has to be stopped here.
ENUM_VALUES = {
    "ENUM_APPLIED_PRICE": {"PRICE_CLOSE", "PRICE_OPEN", "PRICE_HIGH",
                           "PRICE_LOW", "PRICE_MEDIAN", "PRICE_TYPICAL",
                           "PRICE_WEIGHTED"},
    "ENUM_MA_METHOD": {"MODE_SMA", "MODE_EMA", "MODE_SMMA", "MODE_LWMA"},
    "ENUM_STO_PRICE": {"STO_LOWHIGH", "STO_CLOSECLOSE"},
    "ENUM_APPLIED_VOLUME": {"VOLUME_TICK", "VOLUME_REAL"},
}
TIMEFRAMES = {f"PERIOD_{t}" for t in (
    "M1 M2 M3 M4 M5 M6 M10 M12 M15 M20 M30 "
    "H1 H2 H3 H4 H6 H8 H12 D1 W1 MN1").split()}
NOT_IMPLEMENTED = {"iCustom"}
DATE_RE = re.compile(r"^\d{4}\.\d{2}\.\d{2}( \d{2}:\d{2}(:\d{2})?)?$")


class BridgeError(RuntimeError):
    """The EA dropped the request without an answer, or never picked it up."""


# ================================================================
# Reference table
# ================================================================
def load_etalon() -> dict:
    """Load indicators_etalon.json - the single source of truth shared
    by both sides of the bridge."""
    with open(ETALON_FILE, "r", encoding="utf-8") as f:
        return json.load(f)["indicators"]


# ================================================================
# Validation
# ================================================================
def validate_request(request: dict, etalon: dict) -> list[str]:
    """Check a request against the reference table.

    Returns the list of problems found; an empty list means the request is
    valid. Validating here costs milliseconds, while the same mistake found
    by the EA costs a full request round trip - and an enum typo is not
    found by the EA at all.
    """
    errors = []

    if request.get("timeframe") not in TIMEFRAMES:
        errors.append(f"timeframe '{request.get('timeframe')}' is not one of "
                      f"PERIOD_M1 .. PERIOD_MN1 (the EA would use PERIOD_H1)")
    for key in ("start_date", "end_date"):
        if not DATE_RE.match(str(request.get(key, ""))):
            errors.append(f"{key} '{request.get(key)}' is not 'YYYY.MM.DD'"
                          f" or 'YYYY.MM.DD HH:MM'")

    columns = []
    for ind in request["indicators"]:
        name = ind["name"]

        if name not in etalon:
            errors.append(f"{name}: not found in the reference table")
            continue
        if name in NOT_IMPLEMENTED:
            errors.append(f"{name}: listed in the reference table, "
                          f"but BridgeEA has no CreateHandle branch for it")
            continue

        spec = etalon[name]
        etalon_params = [p["name"] for p in spec["params"]]
        request_params = list(ind["params"].keys())

        # Parameter count must match exactly.
        if len(request_params) != len(etalon_params):
            errors.append(
                f"{name}: params count {len(request_params)} "
                f"!= reference {len(etalon_params)}"
            )

        # Order matters: position in the dict is the position in the MQL5 call.
        for i, (rp, ep) in enumerate(zip(request_params, etalon_params)):
            if rp != ep:
                errors.append(f"{name}: param[{i}] '{rp}' != reference '{ep}'")

        # Enum values must be strings the EA actually converts.
        for p in spec["params"]:
            allowed = ENUM_VALUES.get(p["type"])
            value = ind["params"].get(p["name"])
            if allowed and value is not None and value not in allowed:
                errors.append(f"{name}: {p['name']}='{value}' is not one of "
                              f"{sorted(allowed)}")

        # Buffer indices must exist in the indicator.
        valid_indices = set(spec["buffers"].values())
        for col_name, buf_idx in ind["buffers"].items():
            if buf_idx not in valid_indices:
                errors.append(
                    f"{name}: buffer '{col_name}' index {buf_idx} "
                    f"is not one of {sorted(valid_indices)}"
                )
            columns.append(col_name)

    reserved = {"datetime", "open", "high", "low", "close"}
    dupes = sorted({c for c in columns if columns.count(c) > 1}
                   | (set(columns) & reserved))
    if dupes:
        errors.append(f"duplicate or reserved CSV column names: {dupes}")

    return errors


def lookahead_warnings(request: dict) -> list[str]:
    """Buffers whose value at bar t depends on bars after t.

    Not an error - such a column can be wanted for labelling - but as a
    feature it is peeking into the future.
    """
    warns = []
    for ind in request["indicators"]:
        name = ind["name"]
        if name == "iIchimoku" and 4 in ind["buffers"].values():
            warns.append("iIchimoku buffer 4 (chikou_span) at bar t holds "
                         "close[t + kijun_sen]")
        for key, value in ind["params"].items():
            if key.endswith("shift") and isinstance(value, (int, float)) \
                    and value < 0:
                warns.append(f"{name}: {key}={value} shifts the line "
                             f"backwards - future bars leak into bar t")
    if str(request.get("end_date", "")) >= date.today().strftime("%Y.%m.%d"):
        warns.append(f"end_date {request['end_date']} reaches today - the "
                     f"last bar may still be forming")
    return warns


# ================================================================
# Sending
# ================================================================
def send_request(request: dict) -> Path:
    """Write the request atomically: a temporary file first, then a rename.

    The EA scans for request_*.json, so a partially written file can never
    be picked up - the temporary name does not match the pattern.
    """
    req_file = COMMON_FILES / f"request_{request['request_id']}.json"
    tmp_file = req_file.with_name(req_file.name + ".tmp")

    # The EA reads with FILE_ANSI / CP_ACP, so both sides use the same code page.
    with open(tmp_file, "w", encoding="ansi", newline="\n") as f:
        f.write(json.dumps(request, indent=2))

    tmp_file.replace(req_file)
    print(f"[send]  {req_file.name}", flush=True)
    return req_file


# ================================================================
# EA journal
# ================================================================
def journal_lines(request_id: str) -> list[str]:
    """EA journal lines that belong to one request.

    The journal is UTF-16 and the running terminal flushes it lazily, so
    for a request made a second ago this may come back empty - then the
    path is the useful part of the message.
    """
    if TERMINAL_DATA is None:
        return []
    logs = TERMINAL_DATA / "MQL5/Logs"
    out = []
    for day in (date.today() - timedelta(days=1), date.today()):
        f = logs / f"{day:%Y%m%d}.log"
        if not f.exists():
            continue
        try:
            text = f.read_text(encoding="utf-16", errors="replace")
        except OSError:
            continue
        inside = False
        for line in text.splitlines():
            if f"request_{request_id}.json" in line:
                inside = True
            if inside and "BridgeEA" in line:
                out.append(line.split("\t", 3)[-1].strip())
            if inside and f"[{request_id}]" in line:
                inside = False
    return out


def _failure_message(request_id: str, what: str) -> str:
    lines = journal_lines(request_id)
    tail = ("\n    " + "\n    ".join(lines[-8:])) if lines else (
        f"\n    (journal not flushed yet: {TERMINAL_DATA / 'MQL5/Logs'})" if TERMINAL_DATA
        else "\n    (terminal data folder unknown: set terminal_data in paths.json)")
    return f"{what} (request_id={request_id}){tail}"


# ================================================================
# Waiting
# ================================================================
def wait_for_response(request_id: str,
                      timeout_sec: int = RESPONSE_TIMEOUT_SEC) -> Path:
    """Wait until the EA has finished.

    Waiting for the CSV alone is not enough: the EA renames the response into
    place and only then deletes the request. Both conditions together mean the
    file is complete.

    The request is checked BEFORE the response. If it is already gone, then
    any response the EA was going to write is already in place, so "no
    response" at that moment is a definite failure, not a race.
    """
    req_file = COMMON_FILES / f"request_{request_id}.json"
    resp_file = COMMON_FILES / f"response_{request_id}.csv"
    deadline = time.time() + timeout_sec

    while time.time() < deadline:
        req_gone = not req_file.exists()
        if resp_file.exists():
            if req_gone:
                print(f"[recv]  {resp_file.name}", flush=True)
                return resp_file
        elif req_gone:
            raise BridgeError(_failure_message(
                request_id, "the EA dropped the request without an answer"))
        time.sleep(POLL_INTERVAL_SEC)

    # Still unanswered. Withdraw the request so it is not processed later,
    # out of context, after the caller has moved on.
    if req_file.exists():
        try:
            req_file.unlink()
        except OSError:
            pass
        raise BridgeError(
            f"the EA did not pick up request_{request_id}.json within "
            f"{timeout_sec}s - is the terminal running with BridgeEA on a chart?")
    raise BridgeError(_failure_message(
        request_id, f"no complete answer within {timeout_sec}s"))


# ================================================================
# Full cycle
# ================================================================
def fetch_csv(request: dict,
              retries: int = RETRIES,
              timeout_sec: int = RESPONSE_TIMEOUT_SEC) -> Path:
    """Validate, then send / wait with retries. Returns the response CSV path.

    Each attempt gets a fresh request_id: a reused id could match a stale
    response file of the failed attempt. The id that succeeded is written
    back into request["request_id"].
    """
    errors = validate_request(request, load_etalon())
    if errors:
        raise ValueError(
            "request rejected:\n" + "\n".join(f"  - {e}" for e in errors)
        )
    for w in lookahead_warnings(request):
        print(f"[warn]  {w}", flush=True)

    last = None
    for attempt in range(1, retries + 1):
        if attempt > 1 or not request.get("request_id"):
            request["request_id"] = uuid.uuid4().hex[:8]
        try:
            send_request(request)
            return wait_for_response(request["request_id"], timeout_sec)
        except BridgeError as e:
            last = e
            print(f"[fail]  attempt {attempt}/{retries}: {e}", flush=True)
            if "did not pick up" in str(e):
                break  # the EA is not running - retrying will not help
            time.sleep(2)
    raise last


def read_response(csv_path: Path) -> pd.DataFrame:
    """Response CSV -> DataFrame, oldest bar first."""
    df = pd.read_csv(csv_path)
    df["datetime"] = pd.to_datetime(df["datetime"], format="%Y.%m.%d %H:%M")
    return df.sort_values("datetime").reset_index(drop=True)


def run_pipeline(request: dict, keep_csv: bool = False,
                 retries: int = RETRIES,
                 timeout_sec: int = RESPONSE_TIMEOUT_SEC) -> pd.DataFrame:
    """Validate, send, wait, read, clean up.

    Rows come back in chronological order - oldest bar first.
    """
    csv_path = fetch_csv(request, retries, timeout_sec)
    df = read_response(csv_path)

    if not keep_csv:
        csv_path.unlink()

    print(f"[done]  {len(df)} rows, {len(df.columns)} columns, "
          f"{df['datetime'].iloc[0]} -> {df['datetime'].iloc[-1]}")
    return df


# ================================================================
# Example
# ================================================================
if __name__ == "__main__":
    demo_request = {
        "symbol":     "EURUSD",
        "timeframe":  "PERIOD_H1",
        "start_date": "2020.01.01",
        "end_date":   (date.today() - timedelta(days=1)).strftime("%Y.%m.%d"),
        "indicators": [
            {
                "name": "iRSI",
                "params": {
                    "ma_period":     14,
                    "applied_price": "PRICE_CLOSE"
                },
                "buffers": {"rsi14": 0}
            },
            {
                "name": "iMACD",
                "params": {
                    "fast_ema_period": 12,
                    "slow_ema_period": 26,
                    "signal_period":    9,
                    "applied_price":   "PRICE_CLOSE"
                },
                "buffers": {
                    "macd_line":   0,
                    "macd_signal": 1
                }
            },
            {
                "name": "iAlligator",
                "params": {
                    "jaw_period":    13,
                    "jaw_shift":      8,
                    "teeth_period":   8,
                    "teeth_shift":    5,
                    "lips_period":    5,
                    "lips_shift":     3,
                    "ma_method":     "MODE_SMMA",
                    "applied_price": "PRICE_MEDIAN"
                },
                "buffers": {
                    "alligator_jaw":   0,
                    "alligator_teeth": 1,
                    "alligator_lips":  2
                }
            }
        ]
    }

    frame = run_pipeline(demo_request)
    print(frame.head())
