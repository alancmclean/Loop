import sys, numpy as np, pandas as pd
hd = sys.argv[1]; START, END = "2026-06-01", "2026-11-27"
cols = ["start","end","value","unit","source","reason","meta"]
def dst(x):
    x = pd.to_datetime(x); m = (x >= "2026-03-08 02:00") & (x < "2026-11-01 01:00")
    return x + pd.to_timedelta(m.astype(int), unit="h")
E = pd.Timestamp("2000-01-01"); M = lambda s: ((s - E).dt.total_seconds() // 60).astype(float)
g = pd.read_csv(f"{hd}/glucose.csv", names=cols); g=g[g.source=="Loop"]; g["s"]=dst(g.start.str[:19]); g=g[(g.s>=START)&(g.s<END)].drop_duplicates("s").sort_values("s")
gt=M(g.s).values; gv=g.value.astype(float).values
ins = pd.read_csv(f"{hd}/insulin.csv", names=cols, low_memory=False); ins=ins[ins.source=="Loop"]; ins["s"]=dst(ins.start.str[:19]); ins=ins[(ins.s>=START)&(ins.s<END)]
ins["t"]=M(ins.s); auto=ins.meta.fillna("").str.contains("AutomaticallyIssued=1")
man=ins[(ins.reason==2)&~auto]; aut=ins[(ins.reason==2)&auto]
w = pd.read_csv(f"{hd}/workouts.csv", names=["start","end","type","dur","source"]); w["s"]=dst(w.start.str[:19]); w["e"]=dst(w.end.str[:19]); w=w[(w.s>=START)&(w.s<END)]
rides=[(a,b) for a,b in zip(M(w.s).values, M(w.e).values) if b-a>=20]
def episodes(cond, gap=120):
    out=[]; last=-1e9
    for t,v in zip(gt,gv):
        if cond(v):
            if t-last>gap: out.append(t)
            last=t
    return np.array(out)
lows=episodes(lambda v:v<70); highs=episodes(lambda v:v>180)
def followed(a, b, lo, hi): return np.array([((b>x+lo)&(b<=x+hi)).any() for x in a])
lh = followed(lows, highs, 0, 180)
print(f"low episodes {len(lows)}; followed by >180 within 3 h (rebound): {lh.mean()*100:.0f}%")
hl = followed(highs, lows, 0, 300)
print(f"high episodes {len(highs)}; followed by <70 within 5 h: {hl.mean()*100:.0f}%")
# of highs followed by lows, how much insulin (manual+auto boluses) was given in the 2 h after the high started
def bolus_after(ts, src, lo=0, hi=120): return np.array([src[(src.t>=x+lo)&(src.t<x+hi)].value.astype(float).sum() for x in ts])
hm, ha = bolus_after(highs, man), bolus_after(highs, aut)
print(f"insulin given in the 2 h after a high starts: highs that ended low {np.median(hm[hl]+ha[hl]):.1f} U (manual {np.median(hm[hl]):.1f}), highs that didn't {np.median(hm[~hl]+ha[~hl]):.1f} U (manual {np.median(hm[~hl]):.1f})")
# after rides: rebound pattern
post=[x for x in lows if any(0<=x-e<720 for s,e in rides)]
pr=followed(np.array(post), highs, 0, 180)
print(f"post-ride lows (0-12 h): {len(post)}; rebound >180 within 3 h: {pr.mean()*100:.0f}%")
ph=[x for x in highs if any(0<=x-e<360 for s,e in rides)]
phl=followed(np.array(ph), lows, 0, 300)
print(f"highs within 6 h after a ride: {len(ph)}; then low within 5 h: {phl.mean()*100:.0f}% (vs {hl.mean()*100:.0f}% for all highs)")
