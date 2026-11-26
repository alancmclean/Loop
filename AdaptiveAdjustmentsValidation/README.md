# Adaptive Adjustments — validation

Offline tools used to test the Adaptive Adjustments layer without testing on a person.
Not part of the app build.

## Simulation (`run.py`)
- Virtual patients: UVA/Padova model via the `simglucose` package (`pip install simglucose`).
- Controller: a simplified Loop-style controller (`controller.py`: exponential insulin model,
  carb entries, retrospective correction, temp basal + 40% automatic bolus, suspend on predicted low).
- World (`world.py`): hidden effects the layer never sees directly — exercise (−45% during/2 h, −20% to 12 h),
  short sleep (+20%), site day 3 (12% less absorption), site failures, illness (+35%), hidden stress (+15%),
  alcohol (−20% delayed), dawn phenomenon, day-to-day noise; carb entries undercounted, 15% of meals
  never entered, unannounced snacks.
- `adaptive.py` mirrors the Swift logic.

Run: `python3 run.py out.json 50 30 --variant v2` (30 days learning, 20 days evaluated).

### Results (6 virtual adults, 20 evaluated days each; plain Loop: TIR 91.6%, <70 3.75%)
| Version | Δ TIR | Δ time <70 | Δ time <54 |
|---|---|---|---|
| Original (delivered insulin, 3 h meal window, weekend signal) | +0.06 | −0.31 | +0.09 |
| v1: insulin activity, 5 h meal exclusion, ≥4 episodes, no weekend signal | +0.63 | −0.39 | −0.13 |
| **v2: v1 + reduce-only priors (exercise, alcohol) — shipped** | **+0.68** | **−0.86** | **−0.24** |
| v3: v2 + outcome feedback tuning — not shipped (noisy factors, no gain) | +0.52 | −0.80 | −0.25 |

## Real-data replay (`parse_health.py`, `analyze_real.py`)
Replays the analysis on an Apple Health export, offline. Findings that changed the design:
- Recent-sensitivity (autosens) measured against scheduled basal was biased upward every day
  (median 1.11, never below 0.9) — it was measuring a settings mismatch. Now compared with the
  person's own 30-day baseline; even then day-to-day values didn't persist (lag-1 correlation −0.3),
  so it is **off by default**.
- Exercise next to meals/boluses means the insulin-based learner rarely sees clean post-exercise
  hours; glucose outcomes still showed more lows after exercise. Hence the reduce-only exercise priors.
- Weekend showed no effect; the weekend signal is removed.

Never commit health data to this repository.
