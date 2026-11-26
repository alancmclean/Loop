"""Replay new strategies on real data (offline): ride prediction, guard coverage, time-of-day profile."""
import sys, json, numpy as np
SRC = sys.argv[1]; sys.argv = sys.argv[1:]
exec(open(SRC).read().split("# ---- Overview")[0])
from controller import iob_fraction
R = {}
DAYM = 1440
gt = np.array([t for t, _ in glucose]); gv = np.array([v for _, v in glucose], dtype=float)

# --- 1. Ride habit prediction (rolling, habits from prior 28 days)
prep_minutes = 0; prep_windows = 0; prep_hit = 0; rides_covered = 0; rides_total = 0
for d in range(int(t0 // DAYM) + 28, int(t1 // DAYM)):
    now = d * DAYM
    hab = A.ride_habits(workouts, now)
    wk = (d % 7) in (5, 6)
    todays = [s for s, e in workouts if now <= s < now + DAYM and e - s >= 20]
    for hwk, minute, f in hab:
        if hwk != wk: continue
        prep_windows += 1
        slot = now + minute
        if any(slot - 75 <= s <= slot + 60 for s in todays): prep_hit += 1
    for s in todays:
        rides_total += 1
        if any(hwk == wk and now + minute - 75 <= s <= now + minute + 60 for hwk, minute, f in hab): rides_covered += 1
R["ride_prediction"] = dict(prep_windows=prep_windows, followed_by_ride_pct=round(100 * prep_hit / max(1, prep_windows)),
                            rides=rides_total, rides_predicted_pct=round(100 * rides_covered / max(1, rides_total)))
R["habits_latest"] = [(("weekend" if wk else "weekday"), f"{m // 60}:{m % 60:02d}", round(f, 2)) for wk, m, f in A.ride_habits(workouts, t1)]

# --- low episodes
lows = []; last = -10 ** 9
for t, v in glucose:
    if v < 70:
        if t - last > 180: lows.append(t)
        last = t
lows = np.array(lows)
R["low_episodes"] = len(lows)
ride_list = [(s, e) for s, e in workouts if e - s >= 20]
def after_ride(t, a, b): return any(a <= t - e <= b for s, e in ride_list)
R["lows_0_3h_after_ride_pct"] = round(100 * np.mean([after_ride(t, 0, 180) for t in lows]))
R["lows_0_8h_after_ride_pct"] = round(100 * np.mean([after_ride(t, -45, 480) for t in lows]))
ev = [t for t in lows if 16 <= (t // 60) % 24 < 21]
R["evening_lows"] = len(ev); R["evening_lows_after_ride_0_8h_pct"] = round(100 * np.mean([after_ride(t, -45, 480) for t in ev])) if ev else None

# --- 2. Stacking guard: IOB from boluses + net basal vs scheduled
bol = ins[ins.reason == 2]; bas = ins[(ins.reason == 1)]
bt = bol.t.values.astype(float); bu = bol.value.values.astype(float)
# net basal per 5-min record
bas_mid = ((bas.t + bas.te) / 2).values.astype(float)
bas_net = (bas.value.values.astype(float) - bas.sched.fillna(np.nan).values * (bas.te - bas.t).values / 60.0)
okb = ~np.isnan(bas_net)
dt_all = np.concatenate([bt, bas_mid[okb]]); du_all = np.concatenate([bu, bas_net[okb]])
order = np.argsort(dt_all); dt_all = dt_all[order]; du_all = du_all[order]
def iob_at(t):
    i0, i1 = np.searchsorted(dt_all, t - 370), np.searchsorted(dt_all, t)
    return float(np.sum(du_all[i0:i1] * iob_fraction(t - dt_all[i0:i1])))
samp = gt[::1]
iob = np.array([iob_at(t) for t in samp])
hod = (samp // 60) % 24
guard = np.zeros(len(samp), bool)
for i in range(len(samp)):
    if i < 2: continue
    h = hod[i]
    win = (samp < samp[i]) & (samp >= samp[i] - 14 * DAYM) & (hod == h)
    if i % 1 == 0:
        pass
# vectorised typical IOB per hour over the trailing 14 days: approximate with a daily refresh
typ = {}
for d in range(int(t0 // DAYM), int(t1 // DAYM) + 1):
    m = (samp >= (d - 14) * DAYM) & (samp < d * DAYM)
    for h in range(24):
        x = iob[m & (hod == h)]
        typ[(d, h)] = float(np.median(x)) if len(x) >= 30 else None
rate = np.zeros(len(samp)); rate[2:] = (gv[2:] - gv[:-2]) / np.maximum(1, (gt[2:] - gt[:-2]))
for i in range(2, len(samp)):
    ty = typ.get((int(samp[i] // DAYM), int(hod[i])))
    guard[i] = ty is not None and iob[i] > max(2.0, 1.8 * ty) and gv[i] < 150 and rate[i] <= 0.5
def guard_before(t, a=90, b=20):
    m = (samp >= t - a) & (samp <= t - b)
    return bool(guard[m].any())
R["stack_guard"] = dict(active_pct_of_time=round(100 * guard.mean(), 1),
    lows_with_guard_active_20_90min_before_pct=round(100 * np.mean([guard_before(t) for t in lows])),
    random_times_with_guard_active_20_90min_before_pct=round(100 * np.mean([guard_before(t) for t in np.random.default_rng(2).choice(samp, 1500)])),
    median_iob=round(float(np.median(iob)), 2))

# --- 3. Time-of-day profile from outcomes (as the app would converge to, using last 28 days)
prof = {}
for d in range(int(t1 // DAYM) - 28, int(t1 // DAYM)):
    now = d * DAYM
    prof = A.update_tod_profile(prof, [x for x in glucose if now - 7 * DAYM <= x[0] < now])
R["tod_profile_static_28d"] = {h: round(prof.get(h, 1.0), 2) for h in range(24) if abs(prof.get(h, 1.0) - 1) > 0.001}
R["note"] = "Profile above is what repeated updates would reach if outcomes did not change in response (upper bound)."
print(json.dumps(R, indent=1))
