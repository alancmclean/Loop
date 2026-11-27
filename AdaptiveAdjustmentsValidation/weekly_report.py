"""Prototype of the weekly report analysis (mirrors AdaptiveOverrideReport.swift).
Usage: python3 -I weekly_report.py <hd_out dir> <end 'YYYY-MM-DD HH:MM'>"""
import sys, numpy as np, pandas as pd

hd, END = sys.argv[1], pd.Timestamp(sys.argv[2])
START, PSTART = END - pd.Timedelta(days=7), END - pd.Timedelta(days=14)
cols = ["start", "end", "value", "unit", "source", "reason", "meta"]

def dst(x):
    x = pd.to_datetime(x); m = (x >= "2026-03-08 02:00") & (x < "2026-11-01 01:00")
    return x + pd.to_timedelta(m.astype(int), unit="h")

g = pd.read_csv(f"{hd}/glucose.csv", names=cols); g = g[g.source == "Loop"]
g["t"] = dst(g.start.str[:19]); g = g[(g.t >= PSTART) & (g.t < END)].drop_duplicates("t").sort_values("t")
g["v"] = g.value.astype(float)
ins = pd.read_csv(f"{hd}/insulin.csv", names=cols, low_memory=False); ins = ins[ins.source == "Loop"]
ins["t"] = dst(ins.start.str[:19]); ins["te"] = dst(ins.end.str[:19]); ins = ins[(ins.t >= PSTART - pd.Timedelta(hours=8)) & (ins.t < END)]
ins["u"] = ins.value.astype(float); meta = ins.meta.fillna("")
ins["bolus"] = ins.reason == 2; ins["auto"] = meta.str.contains("AutomaticallyIssued=1")
ins["sched"] = meta.str.extract(r"ScheduledBasalRate=([\d.]+)")[0].astype(float)
carbs = pd.read_csv(f"{hd}/carbs.csv", names=cols); carbs["t"] = dst(carbs.start.str[:19])
carbs = carbs[(carbs.t >= PSTART) & (carbs.t < END) & (carbs.source == "Loop")]
w = pd.read_csv(f"{hd}/workouts.csv", names=["start", "end", "type", "dur", "source"])
w["s"] = dst(w.start.str[:19]); w["e"] = dst(w.end.str[:19])
rides = w[(w.s >= START - pd.Timedelta(hours=12)) & (w.s < END) & ((w.e - w.s) >= pd.Timedelta(minutes=15))]

def metrics(v):
    v = np.asarray(v, float)
    if len(v) == 0: return None
    m = v.mean(); sd = v.std(ddof=1)
    f = lambda c: c.mean() * 100
    return dict(n=len(v), coverage=len(v) / (7 * 288) * 100, mean=m, cv=sd / m * 100, gmi=3.31 + 0.02392 * m,
                tir=f((v >= 70) & (v <= 180)), tight=f((v >= 70) & (v <= 140)), b70=f(v < 70), b54=f(v < 54),
                a180=f(v > 180), a250=f(v > 250))

wk = g[(g.t >= START) & (g.t < END)]; pw = g[(g.t >= PSTART) & (g.t < START)]
M, P = metrics(wk.v), metrics(pw.v)

def episodes(df, cond, merge_gap, min_dur):
    out = []; cur = None
    for t, v in zip(df.t, df.v):
        if cond(v):
            if cur and (t - cur["end"]) <= pd.Timedelta(minutes=merge_gap):
                cur["end"] = t; cur["ext"] = min(cur["ext"], v) if v < 100 else max(cur["ext"], v); cur["n"] += 1
            else:
                if cur: out.append(cur)
                cur = dict(start=t, end=t, ext=v, n=1)
    if cur: out.append(cur)
    return [e for e in out if (e["end"] - e["start"]) >= pd.Timedelta(minutes=min_dur) and e["n"] >= 2]

RISES = []
def detect_meals(df, bol):
    # Glucose rise >= 40 in 60 min (start of rise), or manual bolus >= 1 U at glucose <= 150; merged within 90 min.
    t = df.t.values; v = df.v.values; starts = []; i = 0
    while i < len(t):
        j = i + 1; found = None
        while j < len(t) and (t[j] - t[i]) <= np.timedelta64(60, "m"):
            if v[j] - v[i] >= 40: found = j; break
            j += 1
        if found is not None:
            starts.append(pd.Timestamp(t[i])); RISES.append(pd.Timestamp(t[i])); k = found
            while k + 1 < len(t) and v[k + 1] >= v[k] - 5: k += 1
            i = k + 1
        else: i += 1
    for _, b in bol.iterrows():
        near = df[(df.t >= b.t - pd.Timedelta(minutes=10)) & (df.t <= b.t + pd.Timedelta(minutes=10))]
        if b.u >= 1 and len(near) and near.v.iloc[0] <= 150: starts.append(b.t)
    starts.sort(); merged = []
    for s in starts:
        if not merged or s - merged[-1] > pd.Timedelta(minutes=90): merged.append(s)
    return merged

gall = g; manual = ins[ins.bolus & ~ins.auto]; autob = ins[ins.bolus & ins.auto]
meals = detect_meals(gall, manual)
lows_all = episodes(gall, lambda v: v < 70, 15, 10)
highs_all = episodes(gall, lambda v: v > 180, 30, 30)
lows = [e for e in lows_all if START <= e["start"] < END]
highs = [e for e in highs_all if START <= e["start"] < END]

def within(ts, a, b): return [x for x in ts if a <= x < b]
def low_context(e):
    s = e["start"]
    for _, r in rides.iterrows():
        if r.s <= s <= r.e + pd.Timedelta(minutes=60): return "During or just after a ride"
    for _, r in rides.iterrows():
        if r.e + pd.Timedelta(minutes=60) < s <= r.e + pd.Timedelta(hours=12): return "Hours after a ride"
    if any(h["start"] < s and h["end"] >= s - pd.Timedelta(hours=5) for h in highs_all): return "After a high (correction)"
    if s.hour < 6: return "Overnight"
    if within(meals, s - pd.Timedelta(hours=4), s): return "After a meal"
    return "Other"
def high_context(e):
    s = e["start"]
    if any(l["end"] < s and l["end"] >= s - pd.Timedelta(hours=3) for l in lows_all): return "Rebound after a low"
    if within(meals, s - pd.Timedelta(hours=3), s + pd.Timedelta(minutes=15)): return "After a meal"
    if s.hour < 6: return "Overnight"
    return "No meal or low before it"

print(f"Window {START} → {END}")
for k in ["coverage", "tir", "tight", "b70", "b54", "a180", "a250", "mean", "cv", "gmi"]:
    print(f"  {k:9s} {M[k]:6.1f}   prev {P[k]:6.1f}   Δ {M[k]-P[k]:+.1f}")
print(f"Lows {len(lows)} (severe {sum(e['ext']<54 for e in lows)}), highs {len(highs)}")
from collections import Counter
print("  low contexts", Counter(low_context(e) for e in lows))
print("  high contexts", Counter(high_context(e) for e in highs))
hl = [any(l["start"] > h["end"] - pd.Timedelta(minutes=0) and l["start"] <= h["end"] + pd.Timedelta(hours=5) for l in lows_all) for h in highs]
lh = [any(h["start"] > l["end"] and h["start"] <= l["end"] + pd.Timedelta(hours=3) for h in highs_all) for l in lows]
print(f"Roller coaster: highs→low {sum(hl)}/{len(highs)}, lows→high {sum(lh)}/{len(lows)}")
def bolused(df, a, b): return df[(df.t >= a) & (df.t < b)].u.sum()
ins_hl = [bolused(manual, h["start"], h["start"] + pd.Timedelta(hours=2)) + bolused(autob, h["start"], h["start"] + pd.Timedelta(hours=2)) for h in highs]
a = [x for x, f in zip(ins_hl, hl) if f]; b = [x for x, f in zip(ins_hl, hl) if not f]
print(f"  insulin in 2 h after high starts: ended low {np.median(a) if a else float('nan'):.1f} U, didn't {np.median(b) if b else float('nan'):.1f} U")
# stacked manual corrections: manual bolus within 90 min after another manual bolus while glucose > 180
mb = manual[(manual.t >= START) & (manual.t < END)].sort_values("t"); stacked = 0
for i in range(1, len(mb)):
    if mb.t.iloc[i] - mb.t.iloc[i - 1] <= pd.Timedelta(minutes=90):
        gv = gall[(gall.t <= mb.t.iloc[i])].v
        if len(gv) and gv.iloc[-1] > 180: stacked += 1
print(f"  stacked manual corrections: {stacked}")
treated = sum(1 for l in lows if len(carbs[(carbs.t >= l["start"] - pd.Timedelta(minutes=10)) & (carbs.t <= l["end"] + pd.Timedelta(minutes=30))]))
print(f"  lows with carbs logged: {treated}/{len(lows)}")

slot = lambda h: "Breakfast" if 4 <= h < 11 else "Lunch" if h < 16 else "Dinner" if h < 21 else "Late"
rows = []
for m in within(sorted(set(RISES)), START, END):
    gw = gall[(gall.t >= m - pd.Timedelta(minutes=10)) & (gall.t <= m + pd.Timedelta(hours=3))]
    if len(gw) < 12: continue
    bol = manual[(manual.t >= m - pd.Timedelta(minutes=60)) & (manual.t <= m + pd.Timedelta(minutes=30))]
    lead = (m - bol.t.iloc[0]).total_seconds() / 60 if len(bol) else None
    rows.append((slot(m.hour), gw.v.max(), lead))
print("Meals by slot:")
for s in ["Breakfast", "Lunch", "Dinner", "Late"]:
    r = [x for x in rows if x[0] == s]
    if not r: continue
    leads = [x[2] for x in r if x[2] is not None]
    print(f"  {s:9s} n={len(r)} median peak {np.median([x[1] for x in r]):.0f}, >180 {np.mean([x[1]>180 for x in r])*100:.0f}%, bolused {len(leads)}, median lead {np.median(leads) if leads else float('nan'):.0f} min")

# Basal delivered vs scheduled by block (basal records + automatic boluses).
bas = ins[(~ins.bolus) & (ins.t >= START) & (ins.t < END)].copy()
sched_rate = lambda t: 1.2 if t.hour < 6 else 1.3
blocks = [("12–6am", 0, 6), ("6am–12pm", 6, 12), ("12–6pm", 12, 18), ("6pm–12am", 18, 24)]
print("Delivered vs scheduled basal (incl. automatic boluses):")
for name, h0, h1 in blocks:
    fast = lambda t: not within(meals, t - pd.Timedelta(hours=4), t + pd.Timedelta(minutes=1)) and not len(manual[(manual.t > t - pd.Timedelta(hours=4)) & (manual.t <= t)])
    hrs_ = [h for h in pd.date_range(START, END, freq="h", inclusive="left") if h0 <= h.hour < h1 and fast(h)]
    dd = sum(bas[(bas.t >= h) & (bas.t < h + pd.Timedelta(hours=1))].u.sum() + autob[(autob.t >= h) & (autob.t < h + pd.Timedelta(hours=1))].u.sum() for h in hrs_)
    ss = sum(sched_rate(h) for h in hrs_)
    print(f"  {name:9s} fasting hours {len(hrs_):3d}: {dd/ss*100 if ss else float('nan'):5.0f}%")
    d = bas[(bas.t.dt.hour >= h0) & (bas.t.dt.hour < h1)].u.sum() + autob[(autob.t >= START) & (autob.t < END) & (autob.t.dt.hour >= h0) & (autob.t.dt.hour < h1)].u.sum()
    sched = sum(sched_rate(pd.Timestamp("2026-01-01") + pd.Timedelta(hours=h)) for h in range(h0, h1)) * 7
    print(f"  {name:9s} {d/sched*100:5.0f}%   ({d:.1f} of {sched:.1f} U)")
wkins = ins[(ins.t >= START) & (ins.t < END)]; pwins = ins[(ins.t >= PSTART) & (ins.t < START)]
print(f"TDD {wkins.u.sum()/7:.1f} U/day (basal {wkins[~wkins.bolus].u.sum()/7:.1f}, manual bolus {wkins[wkins.bolus&~wkins.auto].u.sum()/7:.1f}, auto bolus {wkins[wkins.bolus&wkins.auto].u.sum()/7:.1f}); prev {pwins.u.sum()/7:.1f}")

print("Rides:")
bolus_all = ins[ins.bolus]
def bolus_iob(t):
    d = bolus_all[(bolus_all.t <= t) & (bolus_all.t > t - pd.Timedelta(hours=6))]
    el = (t - d.t).dt.total_seconds() / 60
    return float((d.u * np.clip(1 - el / 300, 0, 1)).sum())  # rough linear for prototype
for _, r in rides[(rides.s >= START)].iterrows():
    gwin = gall[(gall.t >= r.s) & (gall.t <= r.e + pd.Timedelta(minutes=60))]
    print(f"  {r.s:%a %H:%M} {int((r.e-r.s).total_seconds()/60)} min, IOB≈{bolus_iob(r.s):.1f} U, min glucose {gwin.v.min() if len(gwin) else float('nan'):.0f}")

print("Days:")
for d in pd.date_range(START.normalize(), END.normalize(), freq="D"):
    dd = wk[(wk.t >= d) & (wk.t < d + pd.Timedelta(days=1))]
    if len(dd) < 100: continue
    rode = ((rides.s >= d) & (rides.s < d + pd.Timedelta(days=1))).any()
    print(f"  {d:%a %m-%d} TIR {((dd.v>=70)&(dd.v<=180)).mean()*100:4.0f}%  low {(dd.v<70).mean()*100:4.1f}%  mean {dd.v.mean():4.0f}  {'ride' if rode else ''}")
hrs = wk.groupby(wk.t.dt.hour).v.quantile([.1, .5, .9]).unstack()
print("Hourly median (p10–p90):", " ".join(f"{h}:{r[0.5]:.0f}" for h, r in hrs.iterrows()))
