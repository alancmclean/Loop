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

## Round 2: new strategies (person-like world)
World adds habitual rides (~4/week, 8:00 or 16:30, 30–45 min), 15% lower needs 15:00–20:00 daily,
frequent small no-carb correction boluses, and low treatment (16 g) for everyone.
Plain Loop: TIR 91.0%, <70 2.81%, >180 6.2%.

| Version | Δ TIR | Δ <70 | Δ >180 |
|---|---|---|---|
| v2 (round 1 winner) | +0.84 | −0.20 | −0.63 |
| **v5: + post-exercise target 150 + time-of-day profile — default** | **+0.99** | **−0.58** | **−0.41** |
| v4: v5 + workout prep (auto) + stacking guard | +0.56 | −0.79 | +0.23 |
| v5w: v5 with 50–150% limits | +0.74 | −0.76 | +0.02 |
| v4w: v4 with 50–150% limits | +0.51 | −1.00 | +0.49 |

Wider limits cut lows further but raise highs — offered as a setting, not the default.

Real-data replay of the new ideas (`replay_new.py`):
- Habitual-workout prediction: only ~30% of predicted windows were followed by a ride; ~20% of rides
  were predicted → automatic prep is off by default; a "Workout soon" button is provided instead.
- 44% of 4–9 pm lows occurred within 8 h after a ride → post-exercise target is on by default.
- Stacking guard was active before 28% of lows vs 19% of random times (weak) → off by default.

## Round 3: realistic exercise timing (correction)
Earlier rounds let the simulated phone know about a workout the moment it started. On a real phone,
Apple Health receives a workout only when it ends (Strava rides only after upload). Re-run with
realistic visibility (`ex_info`), same world as round 2:

| v5 (post-exercise target + time-of-day profile) | Δ TIR | Δ <70 | Δ >180 |
|---|---|---|---|
| Unrealistic: workout known at start (round 2 number) | +0.99 | −0.58 | −0.41 |
| **Realistic: known 30 min after it ends** | **+0.84** | **−0.32** | −0.53 |
| **Realistic + motion detection (known 10 min in, ~1 false detection/week)** | +0.55 | **−0.51** | −0.04 |

So round 2 overstated the low reduction by about half. Live motion detection recovers most of it,
at the cost of fewer high reductions (false detections, higher target during rides).

Real data (`ride_timing.py`, 124 rides): 41 rides had a low during the ride or within 30 min of the end
(before Health would know), 78 lows came 3–12 h after; 82% of rides started with >2 U of bolus insulin
on board (median 3.5 U, median 76 min after a manual bolus).

Not simulated yet: the 25%/2 h "Workout soon" defaults (round 2 tested 15%/90 min, automatic).

Never commit health data to this repository.
