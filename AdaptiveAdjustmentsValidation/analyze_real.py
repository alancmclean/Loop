"""Replay the adaptive layer's analysis on real Apple Health data (offline; no dosing).
Usage: python3 -I analyze_real.py HD_OUT_DIR SIM_DIR START END
"""
import sys, json, re, collections
import numpy as np, pandas as pd
hd, simdir, START, END = sys.argv[1:5]
sys.path.insert(0, simdir)
import adaptive as A

cols = ["start", "end", "value", "unit", "source", "reason", "meta"]
EPOCH = pd.Timestamp("2000-01-01")
def mins(ts): return ((ts - EPOCH).dt.total_seconds() // 60).astype(np.int64)
def load(n, src=None):
    d = pd.read_csv(f"{hd}/{n}.csv", names=cols, low_memory=False)
    d["s"] = pd.to_datetime(d.start.str[:19]); d["e"] = pd.to_datetime(d.end.str[:19])
    d = d[(d.s >= START) & (d.s < END)]
    if src: d = d[d.source == src]
    return d.sort_values("s")

g = load("glucose", "Loop")
g = g.drop_duplicates("s")
g["t"] = mins(g.s); g["v"] = g.value.astype(float)
if (g.unit == "mmol/L").any(): g.loc[g.unit == "mmol/L", "v"] *= 18.0
glucose = list(zip(g.t.tolist(), g.v.round().tolist()))

ins = load("insulin", "Loop"); ins["t"] = mins(ins.s); ins["te"] = mins(ins.e)
ins["auto"] = ins.meta.fillna("").str.contains("AutomaticallyIssued=1")
ins["sched"] = ins.meta.fillna("").str.extract(r"ScheduledBasalRate=([\d.]+)")[0].astype(float)
doses = [dict(t=int(r.t), end=int(r.te), units=float(r.value), bolus=(r.reason == 2), manual=(r.reason == 2 and not r.auto))
         for r in ins.itertuples()]
basal_rows = ins[(ins.reason == 1) & ins.sched.notna()]
sched_by_hour = basal_rows.groupby(basal_rows.s.dt.hour).sched.agg(lambda x: x.mode().iloc[-1]).to_dict()
def basal_at(t): return float(sched_by_hour.get(int((t // 60) % 24), np.nan))

carbs = load("carbs", "Loop"); carbs["t"] = mins(carbs.s); carbs["g"] = carbs.value.astype(float)
w = pd.read_csv(f"{hd}/workouts.csv", names=["start", "end", "type", "dur", "source"])
w["s"] = pd.to_datetime(w.start.str[:19]); w["e"] = pd.to_datetime(w.end.str[:19])
w = w[(w.s >= START) & (w.s < END)]
workouts = list(zip(mins(w.s).tolist(), mins(w.e).tolist()))

def series(n):
    try:
        d = load(n); d["t"] = mins(d.s); return list(zip(d.t.tolist(), d.value.astype(float).tolist()))
    except Exception:
        return []
sl = load("sleep"); sl = sl[~sl.value.isin(["HKCategoryValueSleepAnalysisInBed", "HKCategoryValueSleepAnalysisAwake"])]
# nights: merge intervals (gap < 2h)
iv = sorted(zip(mins(sl.s).tolist(), mins(sl.e).tolist()))
nights = []; cs = ce = None; tot = 0
for a, b in iv:
    if ce is not None and a - ce <= 120:
        tot += max(0, b - max(a, ce)); ce = max(ce, b)
    else:
        if ce is not None and tot >= 120: nights.append((ce, tot))
        cs, ce, tot = a, b, b - a
if ce is not None and tot >= 120: nights.append((ce, tot))

ISF = float(sys.argv[5]) if len(sys.argv) > 5 else 45.0
ctx = dict(workouts=workouts, nights=nights, sites=[], hrv=series("hrv"), rhr=series("rhr"), temp=series("temp"), logs=[], use_physio=True)
rules = A.Rules(); rules.use_weekend = True
t0, t1 = glucose[0][0], glucose[-1][0]
R = {}

# ---- Overview
gv = np.array([v for _, v in glucose]); gt = np.array([t for t, _ in glucose])
hours = (gt // 60) % 24
R["overview"] = dict(days=round((t1 - t0) / 1440), readings=len(gv), mean=round(gv.mean()), tir=round(((gv >= 70) & (gv <= 180)).mean() * 100, 1),
    tbr70=round((gv < 70).mean() * 100, 2), tbr54=round((gv < 54).mean() * 100, 2), tar180=round((gv > 180).mean() * 100, 1),
    tar250=round((gv > 250).mean() * 100, 1), cv=round(gv.std() / gv.mean() * 100, 1), gmi=round(3.31 + 0.02392 * gv.mean(), 2))
R["by_hour"] = {int(h): dict(mean=round(gv[hours == h].mean()), low=round((gv[hours == h] < 70).mean() * 100, 1), high=round((gv[hours == h] > 180).mean() * 100, 1)) for h in range(24)}
R["scheduled_basal_by_hour"] = {int(k): v for k, v in sched_by_hour.items()}
tdd = ins.groupby(ins.s.dt.date).value.sum()
R["insulin"] = dict(tdd_median=round(float(tdd.median()), 1), bolus_share_auto=round(float(ins[(ins.reason == 2) & ins.auto].value.sum() / ins[ins.reason == 2].value.sum()), 2),
    manual_boluses_per_day=round(float(((ins.reason == 2) & ~ins.auto).sum() / max(1, len(tdd))), 1))

# ---- Meals: detected vs logged carbs
meals = A.detect_meals(glucose, doses)
ct = carbs.t.values
logged_big = carbs[carbs.g >= 15].t.values
recall = np.mean([any(abs(m - c) <= 60 for m in meals) for c in logged_big]) if len(logged_big) else None
unlogged = [m for m in meals if not any(-30 <= c - m <= 90 for c in ct)]
days = (t1 - t0) / 1440
R["meals"] = dict(carb_entries_per_day=round(len(ct) / days, 1), detected_per_day=round(len(meals) / days, 1),
    logged_meals_found_pct=round(recall * 100) if recall is not None else None,
    detected_without_carb_entry_per_day=round(len(unlogged) / days, 1),
    days_without_any_carb_entry_pct=round(100 * (1 - len(set(carbs.s.dt.date)) / days)))

# ---- Buckets over whole period (activity-based insulin, 5 h meal exclusion)
bk = A.build_buckets(glucose, doses, ctx, t0, t1, rules, meals, meal_after=300, activity=True)
R["buckets"] = dict(hours=len(bk), fasting_hours=sum(A.is_fasting(b) for b in bk))

def learn_on(bs):
    f, e = A.learn(bs, ISF, min_episodes=4)
    return {k: (round(f[k], 2) if k in f else None, e.get(k, 0)) for k in sorted(set(f) | set(e))}
R["learned_all"] = learn_on(bk)
months = sorted({pd.Timestamp(EPOCH + pd.Timedelta(minutes=b["start"])).month for b in bk})
half_a = [b for b in bk if pd.Timestamp(EPOCH + pd.Timedelta(minutes=b["start"])).month % 2 == 0]
half_b = [b for b in bk if pd.Timestamp(EPOCH + pd.Timedelta(minutes=b["start"])).month % 2 == 1]
R["learned_even_months"] = learn_on(half_a); R["learned_odd_months"] = learn_on(half_b)

# ---- Exercise outcomes (glucose only — no carbs involved)
def window_stats(starts, a, b):
    vals = []
    for s in starts:
        i0, i1 = np.searchsorted(gt, s + a), np.searchsorted(gt, s + b)
        if i1 - i0 > (b - a) / 10: vals.append(gv[i0:i1])
    if not vals: return None
    v = np.concatenate(vals)
    return dict(n=len(vals), mean=round(v.mean()), low=round((v < 70).mean() * 100, 1), high=round((v > 180).mean() * 100, 1))
ride_ends = [e for s, e in workouts if e - s >= 20]
ride_days = {e // 1440 for e in ride_ends}
# matched controls: same clock time on days without a workout
ctrl = []
for e in ride_ends:
    tod = e % 1440
    for d in range(int(t0 // 1440), int(t1 // 1440)):
        if d not in ride_days and (d - 1) not in ride_days: ctrl.append(d * 1440 + tod)
def ins_in(starts, a, b):
    tot = []
    for s in starts:
        m = (ins.t >= s + a) & (ins.t < s + b)
        tot.append(ins[m].value.sum())
    return round(float(np.mean(tot)), 2) if tot else None
R["exercise"] = {}
for label, a, b in [("0-3h after", 0, 180), ("3-12h after", 180, 720), ("12-24h after", 720, 1440)]:
    R["exercise"][label] = dict(after_ride=window_stats(ride_ends, a, b), same_time_no_ride=window_stats(ctrl, a, b),
                                insulin_after_ride=ins_in(ride_ends, a, b), insulin_no_ride=ins_in(ctrl[::max(1, len(ctrl) // 400)], a, b))
night_lows = []
R["exercise"]["rides"] = len(ride_ends)
R["exercise"]["ride_start_hours"] = collections.Counter(int((s // 60) % 24) for s, _ in workouts).most_common(6)
R["exercise"]["ride_minutes_median"] = int(np.median([e - s for s, e in workouts])) if workouts else None

# ---- Sleep effect (where sleep data exists)
short = [wk for wk, a in nights if a < 360]; normal = [wk for wk, a in nights if a >= 360]
R["sleep"] = dict(nights=len(nights), short_nights=len(short), next8h_after_short=window_stats(short, 0, 480), next8h_after_normal=window_stats(normal, 0, 480))

# ---- Autosens over time (daily at 6am), and site-failure detector firings
auto = []; alerts = []
gl_t = np.array([x[0] for x in glucose])
day_starts = range(int(t0 // 1440) + 2, int(t1 // 1440))
for d in day_starts:
    now = d * 1440 + 6 * 60
    sub = [b for b in bk if now - 1440 <= b["start"] < now]
    f, n = A.autosens(sub, now, ISF, basal_at)
    auto.append((d, round(f, 3), n))
auto_f = np.array([a[1] for a in auto if a[2] >= 4])
R["autosens"] = dict(days=len(auto), days_with_enough_fasting=len(auto_f),
    median=round(float(np.median(auto_f)), 3) if len(auto_f) else None,
    p10=round(float(np.percentile(auto_f, 10)), 3) if len(auto_f) else None, p90=round(float(np.percentile(auto_f, 90)), 3) if len(auto_f) else None,
    pct_days_above_1_1=round(float((auto_f > 1.1).mean() * 100)) if len(auto_f) else None,
    pct_days_below_0_9=round(float((auto_f < 0.9).mean() * 100)) if len(auto_f) else None,
    day_to_day_corr=round(float(np.corrcoef(auto_f[:-1], auto_f[1:])[0, 1]), 2) if len(auto_f) > 3 else None)
ins_t = ins.t.values; ins_v = ins.value.values
last = -10 ** 9
for k in range(0, len(glucose), 3):     # every 15 min
    now = glucose[k][0]
    if now - last < 180: continue
    i0 = np.searchsorted(gl_t, now - 160)
    win = glucose[i0:k + 1]
    m = (ins_t >= now - 120) & (ins_t < now)
    recent_meals = [x for x in meals if now - 200 <= x <= now]
    if A.site_failure(now, win, float(ins_v[m].sum()), basal_at(now) * 2, recent_meals):
        alerts.append(now); last = now
R["site_alerts"] = dict(count=len(alerts), per_month=round(len(alerts) / days * 30, 1),
    dates=[str((EPOCH + pd.Timedelta(minutes=int(a))).strftime("%Y-%m-%d %H:%M")) for a in alerts][:40])

# ---- Basal suggestions (same tuner logic as the app)
fast = [b for b in bk if A.is_fasting(b)]
byh = collections.defaultdict(list)
for b in fast:
    r = basal_at(b["start"] + 30)
    if r and r > 0.05: byh[b["hour"]].append((b["insulin"] + (b["last"] - b["first"]) / ISF) / r)
R["basal_need_ratio_by_hour"] = {h: dict(n=len(v), median=round(float(np.median(v)), 2)) for h, v in sorted(byh.items())}

# ---- Weekend vs weekday
wk = gt // 1440
dow = ((wk + 5) % 7)   # 2000-01-01 was a Saturday -> 0=Mon
wkend = np.isin(dow, [5, 6])
R["weekend"] = dict(weekday_mean=round(gv[~wkend].mean()), weekend_mean=round(gv[wkend].mean()),
                    weekday_low=round((gv[~wkend] < 70).mean() * 100, 2), weekend_low=round((gv[wkend] < 70).mean() * 100, 2))
print(json.dumps(R, indent=1, default=str))
