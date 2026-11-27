"""Check therapy settings against real data (offline).
Usage: python3 -I settings_check.py HD_OUT SIM START END
Settings are the user's stated values.
"""
import sys, json, collections
import numpy as np, pandas as pd
hd, simdir, START, END = sys.argv[1:5]
sys.path.insert(0, simdir)
from controller import iob_fraction
import adaptive as A

ISF = 32.0
TARGET = 95.0
def basal_set(h): return 1.2 if h < 6 else 1.3
def cr_set(h): return 25.0 if h >= 18 else 18.0

cols = ["start", "end", "value", "unit", "source", "reason", "meta"]
EPOCH = pd.Timestamp("2000-01-01")
def mins(s): return ((s - EPOCH).dt.total_seconds() // 60).astype(np.int64)
def dst(x):
    """Export stamps everything in the current offset (-0500); during US daylight time
    (2026-03-08 to 2026-11-01) real local time is one hour later."""
    x = pd.to_datetime(x)
    m = (x >= "2026-03-08 02:00") & (x < "2026-11-01 01:00")
    return x + pd.to_timedelta(m.astype(int), unit="h")
def load(n):
    d = pd.read_csv(f"{hd}/{n}.csv", names=cols, low_memory=False)
    d["s"] = dst(d.start.str[:19]); d["e"] = dst(d.end.str[:19])
    return d[(d.s >= START) & (d.s < END) & (d.source == "Loop")].sort_values("s")

g = load("glucose").drop_duplicates("s"); g["t"] = mins(g.s); g["v"] = g.value.astype(float)
gt = g.t.values.astype(float); gv = g.v.values
ins = load("insulin"); ins["t"] = mins(ins.s).astype(float); ins["te"] = mins(ins.e).astype(float)
ins["u"] = ins.value.astype(float)
ins["auto"] = ins.meta.fillna("").str.contains("AutomaticallyIssued=1")
ins["sched"] = ins.meta.fillna("").str.extract(r"ScheduledBasalRate=([\d.]+)")[0].astype(float)
ins["manual"] = (ins.reason == 2) & ~ins.auto
ins["basal"] = ins.reason == 1
carbs = load("carbs"); carbs["t"] = mins(carbs.s).astype(float); carbs["g"] = carbs.value.astype(float)
w = pd.read_csv(f"{hd}/workouts.csv", names=["start", "end", "type", "dur", "source"])
w["s"] = dst(w.start.str[:19]); w["e"] = dst(w.end.str[:19])
w = w[(w.s >= START) & (w.s < END)]
rides = list(zip(mins(w.s).astype(float), mins(w.e).astype(float)))

R = {"period": f"{START} to {END}", "days": round((gt[-1] - gt[0]) / 1440)}
# Does the scheduled basal in the data match the stated settings?
bs = ins[ins.basal & ins.sched.notna()]
R["scheduled_basal_seen_in_data_by_hour"] = bs.groupby(bs.s.dt.hour).sched.agg(lambda x: x.mode().iloc[-1]).round(3).to_dict()

# Net insulin (vs scheduled basal) as point doses, for activity calculations.
def sched_rate(t):
    return basal_set(int((t // 60) % 24))
nt, nu = [], []
for r in ins.itertuples():
    if r.basal:
        sr = r.sched if not np.isnan(r.sched) else sched_rate(r.t)
        nt.append((r.t + r.te) / 2); nu.append(r.u - sr * (r.te - r.t) / 60)
    else:
        nt.append(r.t); nu.append(r.u)
order = np.argsort(nt); nt = np.array(nt)[order]; nu = np.array(nu)[order]
def net_activity(a, b):
    """Net insulin (beyond scheduled basal) acting between a and b, in units."""
    i0, i1 = np.searchsorted(nt, a - 380), np.searchsorted(nt, b)
    t_, u_ = nt[i0:i1], nu[i0:i1]
    return float(np.sum(u_ * (iob_fraction(a - t_) - iob_fraction(b - t_))))
def bg_at(t, tol=10):
    i = np.searchsorted(gt, t)
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(gt) and abs(gt[j] - t) <= tol and (best is None or abs(gt[j] - t) < abs(gt[best] - t)): best = j
    return None if best is None else float(gv[best])

man_t = ins[ins.manual].t.values; man_u = ins[ins.manual].u.values
carb_t = carbs.t.values; carb_g = carbs.g.values
gl = list(zip(gt.astype(int).tolist(), gv.round().tolist()))
doses = [dict(t=float(r.t), end=float(r.te), units=float(r.u), bolus=not r.basal, manual=bool(r.manual)) for r in ins.itertuples()]
meals = np.array(A.detect_meals(gl, doses), dtype=float)
def any_in(arr, a, b): return bool(((arr >= a) & (arr < b)).any())
def ride_near(a, b): return any(s < b and e > a for s, e in rides)

# ---------- 1. Basal: fasting hours ----------
# An hour counts if: no carb entry in the previous 5 h or during it, no manual bolus in the previous
# 4 h or during it, no detected meal in the previous 5 h, no ride in the previous 6 h, full CGM.
basal_rows = collections.defaultdict(list)
drift_rows = collections.defaultdict(list)
loop_ratio = collections.defaultdict(list)
h0 = int(gt[0] // 60) + 6
for hh in range(h0, int(gt[-1] // 60)):
    a, b = hh * 60.0, hh * 60.0 + 60
    hour = hh % 24
    # Loop's automatic insulin vs scheduled (all hours, for context)
    m = (ins.t.values >= a) & (ins.t.values < b) & ~ins.manual.values
    if m.any(): loop_ratio[hour].append(ins.u.values[m].sum() / basal_set(hour))
    if any_in(carb_t, a - 300, b) or any_in(man_t, a - 240, b) or any_in(meals, a - 300, b) or ride_near(a - 360, b):
        continue
    b0, b1 = bg_at(a), bg_at(b)
    if b0 is None or b1 is None: continue
    # Insulin needed this hour relative to schedule: scheduled basal + net acting + what would have
    # been needed to keep glucose flat (ΔBG / ISF).
    need = basal_set(hour) + net_activity(a, b) + (b1 - b0) / ISF
    basal_rows[hour].append(need / basal_set(hour))
    drift_rows[hour].append(b1 - b0)
R["basal_fasting_hours"] = {h: dict(n=len(v), need_vs_setting=round(float(np.median(v)), 2),
                                    glucose_drift_per_h=round(float(np.median(drift_rows[h])), 1))
                            for h, v in sorted(basal_rows.items())}
R["loop_automatic_insulin_vs_scheduled_basal_by_hour"] = {h: round(float(np.median(v)), 2) for h, v in sorted(loop_ratio.items())}

# Pooled ISF estimate from fasting hours: ΔBG ≈ (need − actual) ... use correction episodes below instead.

# ---------- 2. ISF: clean corrections ----------
isf_obs = []
for t, u in zip(man_t, man_u):
    if u < 0.7: continue
    b0 = bg_at(t, 6)
    if b0 is None or b0 < 160: continue
    if any_in(carb_t, t - 60, t + 240) or any_in(meals, t - 60, t + 180): continue
    if any_in(man_t, t + 1, t + 180) or any_in(man_t, t - 120, t - 1): continue
    if ride_near(t - 120, t + 240): continue
    b3 = bg_at(t + 180)
    if b3 is None: continue
    act = net_activity(t, t + 180)    # all net insulin acting over the 3 h (incl. Loop's adjustments)
    if act < 0.5: continue
    isf_obs.append(dict(t=t, drop=b0 - b3, act=act, isf=(b0 - b3) / act, b0=b0))
iso = np.array([x["isf"] for x in isf_obs])
R["isf_corrections"] = dict(episodes=len(iso), median_observed_isf=round(float(np.median(iso)), 1) if len(iso) else None,
                             iqr=[round(float(np.percentile(iso, 25)), 1), round(float(np.percentile(iso, 75)), 1)] if len(iso) else None,
                             setting=ISF)

# ---------- 3. Carb ratio: clean meals ----------
cr_rows = collections.defaultdict(list)
cr_detail = collections.defaultdict(list)
for t, gr in zip(carb_t, carb_g):
    if gr < 20: continue
    if any_in(carb_t, t - 180, t - 1) or any_in(carb_t, t + 1, t + 240): continue
    if not any_in(man_t, t - 30, t + 30): continue
    if any_in(man_t, t + 30, t + 240): continue            # no top-up boluses afterwards
    if ride_near(t - 60, t + 240): continue
    b0, b4 = bg_at(t), bg_at(t + 240)
    if b0 is None or b4 is None: continue
    act = net_activity(t - 30, t + 240)
    # Glucose rise the carbs caused = observed change + what the insulin pushed down.
    carb_rise = (b4 - b0) + ISF * act
    if carb_rise <= 5: continue
    eff_cr = gr * ISF / carb_rise      # grams covered per unit, as logged
    h = int((t // 60) % 24)
    slot = "breakfast (5-10am)" if 5 <= h < 10 else "lunch (10am-3pm)" if 10 <= h < 15 else "afternoon (3-6pm)" if 15 <= h < 18 else "dinner/evening (6pm-12am)" if h >= 18 else "night (12-5am)"
    cr_rows[slot].append(eff_cr)
    cr_detail[slot].append(b4 - b0)
R["carb_ratio_meals"] = {k: dict(meals=len(v), effective_g_per_U=round(float(np.median(v)), 1),
                                 median_bg_change_4h=round(float(np.median(cr_detail[k])), 0),
                                 setting=(25.0 if k.startswith("dinner") else 18.0))
                         for k, v in cr_rows.items()}
R["carb_entries_total"] = int(len(carb_t)); R["carb_entries_per_day"] = round(len(carb_t) / R["days"], 1)

# ---------- 4. Outcomes by hour (for correction range) ----------
hrs = (gt // 60) % 24
R["by_hour"] = {int(h): dict(low=round(float((gv[hrs == h] < 70).mean() * 100), 1), high=round(float((gv[hrs == h] > 180).mean() * 100), 1),
                             mean=round(float(gv[hrs == h].mean()))) for h in range(24)}
R["overall"] = dict(tir=round(float(((gv >= 70) & (gv <= 180)).mean() * 100), 1), low70=round(float((gv < 70).mean() * 100), 2),
                    low54=round(float((gv < 54).mean() * 100), 2), high180=round(float((gv > 180).mean() * 100), 1),
                    high250=round(float((gv > 250).mean() * 100), 1), mean=round(float(gv.mean())))
tdd = ins.groupby(ins.s.dt.date).u.sum()
man_share = ins[ins.manual].groupby(ins[ins.manual].s.dt.date).u.sum()
R["insulin"] = dict(tdd_median=round(float(tdd.median()), 1), scheduled_basal_per_day=round(6 * 1.2 + 18 * 1.3, 1),
                    manual_bolus_per_day_median=round(float(man_share.median()), 1))
print(json.dumps(R, indent=1, default=str))
