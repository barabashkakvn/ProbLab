"""Install the bridge into a MetaTrader 5 terminal and compile BridgeEA.

    python install.py            # terminal from paths.json / default
    python install.py --check    # only show where everything would go

Copies:
    mql5/Experts/BridgeEA.mq5   -> <terminal data>/MQL5/Experts/ProbLab/BridgeEA.mq5
    mql5/Include/JAson.mqh      -> <terminal data>/MQL5/Include/JAson.mqh
    common_files/Bridge/indicators_etalon.json -> <Common/Files>/Bridge/
and compiles BridgeEA with MetaEditor. The terminal itself is not started or
touched. An existing, different JAson.mqh is never overwritten silently.
"""
import argparse
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "python"))
import bridge_paths  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="print the paths and stop")
    parser.add_argument("--force-jason", action="store_true", help="overwrite a different JAson.mqh")
    args = parser.parse_args()

    terminal = bridge_paths.terminal()
    data = bridge_paths.terminal_data()
    common = bridge_paths.common_files()
    editor = terminal.parent / "MetaEditor64.exe"
    print(f"terminal      {terminal}  {'ok' if terminal.exists() else 'NOT FOUND'}")
    print(f"terminal data {data}")
    print(f"common files  {common}")
    if not terminal.exists() or data is None:
        sys.exit("Set 'terminal' (and, if needed, 'terminal_data') in bridge/paths.json - "
                 "copy paths.example.json and edit it.")
    if args.check:
        return

    mql5 = data / "MQL5"
    ea = mql5 / "Experts" / "ProbLab" / "BridgeEA.mq5"
    jason = mql5 / "Include" / "JAson.mqh"
    etalon = common / "Bridge" / "indicators_etalon.json"

    source_jason = HERE / "mql5" / "Include" / "JAson.mqh"
    if jason.exists() and not filecmp.cmp(jason, source_jason, shallow=False) and not args.force_jason:
        sys.exit(f"{jason} exists and differs from the bundled version 1.132.\n"
                 "Another program may depend on it. Re-run with --force-jason to replace it.")

    for source, target in ((HERE / "mql5" / "Experts" / "BridgeEA.mq5", ea), (source_jason, jason),
                           (HERE / "common_files" / "Bridge" / "indicators_etalon.json", etalon)):
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        print(f"copied        {target}")

    log = Path(tempfile.gettempdir()) / "BridgeEA_compile.log"
    # MetaEditor returns exit code 1 even on success; the log is authoritative (UTF-16).
    subprocess.run([str(editor), f"/compile:{ea}", f"/inc:{mql5}", f"/log:{log}"], check=False)
    result = [line for line in log.read_text(encoding="utf-16", errors="replace").splitlines()
              if "result" in line.lower() or "error" in line.lower()]
    log.unlink(missing_ok=True)
    print("compile       " + (result[-1].strip() if result else "no log"))
    if not ea.with_suffix(".ex5").exists() or not result or " 0 errors" not in result[-1]:
        sys.exit("Compilation failed - open BridgeEA.mq5 in MetaEditor (F7) to see why.")
    print("\nDone. In MetaTrader 5: Navigator -> Expert Advisors -> ProbLab -> BridgeEA,\n"
          "drag it onto any chart. The Experts tab should say "
          "'BridgeEA: ready, waiting for requests'.")


if __name__ == "__main__":
    main()
