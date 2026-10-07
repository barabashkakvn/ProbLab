"""Five-minute check: is MT5's ATR the ATR from the textbook?

    python quickstart.py                 # EURUSD H1, last 365 days
    python quickstart.py --symbol GBPUSD --timeframe PERIOD_D1 --days 2000

Needs: MetaTrader 5 running with BridgeEA on any chart (install.py).
Asks the terminal for bars + iATR(14) through the bridge, then computes ATR(14)
in Python two ways from the same bars:
    simple  - simple moving average of True Range (what MT5's iATR does)
    Wilder  - Wilder's smoothing, the "textbook" ATR (most Python libraries)
Prints how far each one is from MT5 and saves a chart to out/quickstart_atr.png.
"""
import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "python"))
import create_request as bridge  # noqa: E402

PERIOD = 14
WARMUP = 10 * PERIOD          # Wilder's smoothing remembers its seed for a long time


def true_range(df):
    previous_close = df["close"].shift(1)
    ranges = np.maximum(df["high"], previous_close) - np.minimum(df["low"], previous_close)
    return ranges.fillna(df["high"] - df["low"])


def wilder(values, period):
    out = np.full(len(values), np.nan)
    out[period - 1] = values[:period].mean()
    for i in range(period, len(values)):
        out[i] = (out[i - 1] * (period - 1) + values[i]) / period
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--symbol", default="EURUSD")
    parser.add_argument("--timeframe", default="PERIOD_H1")
    parser.add_argument("--days", type=int, default=365)
    args = parser.parse_args()

    end = date.today() - timedelta(days=1)
    request = {"symbol": args.symbol, "timeframe": args.timeframe,
               "start_date": (end - timedelta(days=args.days)).strftime("%Y.%m.%d"),
               "end_date": end.strftime("%Y.%m.%d"),
               "indicators": [{"name": "iATR", "params": {"ma_period": PERIOD}, "buffers": {"atr_mt5": 0}}]}
    df = bridge.run_pipeline(request)

    tr = true_range(df).to_numpy()
    df["atr_simple"] = np.convolve(tr, np.ones(PERIOD) / PERIOD)[:len(tr)]
    df.loc[:PERIOD - 2, "atr_simple"] = np.nan
    df["atr_wilder"] = wilder(tr, PERIOD)
    df = df.iloc[WARMUP:].reset_index(drop=True)

    print(f"\n{args.symbol} {args.timeframe}, {len(df)} bars "
          f"({df['datetime'].iloc[0]:%Y-%m-%d} .. {df['datetime'].iloc[-1]:%Y-%m-%d})\n")
    print(f"{'ATR(14) in Python':<24}{'max |diff| vs MT5':>20}{'median, % of ATR':>20}{'max, % of ATR':>16}")
    for column, label in (("atr_simple", "simple average of TR"), ("atr_wilder", "Wilder (textbook)")):
        diff = (df[column] - df["atr_mt5"]).abs()
        relative = diff / df["atr_mt5"] * 100
        print(f"{label:<24}{diff.max():>20.8f}{relative.median():>19.3f}%{relative.max():>15.2f}%")
    print("\nThe bridge returns exactly what an expert advisor sees. Recompute an indicator\n"
          "'by the textbook' and your research and your EA silently disagree.")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("\n(matplotlib not installed - chart skipped)")
        return
    out = HERE / "out"
    out.mkdir(exist_ok=True)
    tail = df.tail(300).reset_index(drop=True)
    x = tail.index        # bar number: weekends do not stretch into flat lines
    figure, (top, bottom) = plt.subplots(2, 1, figsize=(10, 6), sharex=True, height_ratios=(2, 1))
    # Okabe-Ito colours: readable with colour-blindness.
    top.plot(x, tail["atr_mt5"], color="#000000", lw=2.2, label="MT5 iATR(14)")
    top.plot(x, tail["atr_simple"], color="#56B4E9", lw=1, ls="--", label="Python: simple average")
    top.plot(x, tail["atr_wilder"], color="#E69F00", lw=1.4, label="Python: Wilder (textbook)")
    top.set_title(f"{args.symbol} {args.timeframe}: ATR(14), last {len(tail)} bars")
    top.legend(frameon=False)
    bottom.plot(x, (tail["atr_wilder"] - tail["atr_mt5"]) / tail["atr_mt5"] * 100, color="#E69F00")
    bottom.axhline(0, color="#999999", lw=0.8)
    bottom.set_ylabel("Wilder vs MT5, %")
    ticks = x[::50]
    bottom.set_xticks(ticks, [f"{tail['datetime'][i]:%m-%d}" for i in ticks])
    figure.tight_layout()
    figure.savefig(out / "quickstart_atr.png", dpi=120)
    print(f"\nchart: {out / 'quickstart_atr.png'}")


if __name__ == "__main__":
    main()
