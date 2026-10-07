# ProbLab — an open lab: what statistics says about trading ideas

> **Research project, not financial advice.** Nothing here is a trading
> recommendation or a promise of profit.

Almost every piece of Forex content sells a "profitable expert advisor".
ProbLab does the opposite: it takes trading ideas, tests them in the open
with MetaTrader 5 and Python, and publishes the result — whatever it is.
Most ideas do not survive the test. **A negative result is not the weak
spot here; it is the main value.**

## Start here

**[bridge/README.md](bridge/README.md)** — install in five minutes and see
why MT5's ATR is not the textbook ATR (typical gap 9 %, worst 59 %).

You need: Windows, MetaTrader 5 (any broker, demo account is fine),
Python 3.10+.

```powershell
git clone https://github.com/barabashkakvn/ProbLab.git
cd ProbLab\bridge
pip install -r requirements.txt
python install.py
```

## What is inside

| Folder | What | Status |
|---|---|---|
| `bridge/` | Python ↔ MQL5 bridge: get bars and indicator buffers exactly as an MT5 expert advisor sees them | release 1 — ready |
| `feature-lab/` | A beginner's path: build features, pick them by eye from charts, train, test — and see why that fails | release 2 — planned |
| `experiments/` | Probability experiments on historical scenarios | release 3+ — planned |

## Principles

- **MT5 is the only data source.** Indicators are taken from the terminal
  itself, not recomputed "by the textbook" — they often differ.
- **Every result is reproducible**: scripts, parameters and dates are
  published; broker quotes are not — a download script is provided instead.
- **Honest conclusions**, including "no stable edge found".
- **No hard-coded paths**: everything outside the repository is set in
  `paths.json` (see each part's README).

## Authors

Volodymyr Karputov ([MQL5 profile](https://www.mql5.com/en/users/barabashkakvn)).
Built together with Claude (Anthropic) as a coding and research assistant.

## License

- Code — [MIT](LICENSE).
- Reports, texts and charts — [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Third-party code keeps its own license (noted in each part).
