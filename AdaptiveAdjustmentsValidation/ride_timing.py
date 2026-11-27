import sys, numpy as np, pandas as pd
sys.path.insert(0, sys.argv[2]); from controller import iob_fraction
hd = sys.argv[1]; START, END = "2026-05-25", "2026-11-27"
cols = ["start","end","value","unit","source","reason","meta"]
def dst(x):
    x = pd.to_datetime(x); m = (x >= "2026-03-08 02:00") & (x < "2026-11-01 01:00")
    return x + pd.to_timedelta(m.astype(int), unit="h")
E = pd.Timestamp("2000-01-01"); M = lambda s: ((s - E).dt.total_seconds() // 60).astype(float)
g = pd.read_csv(f"{hd}/glucose.csv", names=cols); g = g[g.source=="Loop"]; g["s"]=dst(g.start.str[:19]); g=g[(g.s>=START)&(g.s<END)].drop_duplicates("s")
gt = M(g.s).values; gv = g.value.astype(float).values; o=np.argsort(gt); gt,gv=gt[o],gv[o]
w = pd.read_csv(f"{hd}/workouts.csv", names=["start","end","type","dur","source"]); w["s"]=dst(w.start.str[:19]); w["e"]=dst(w.end.str[:19]); w=w[(w.s>=START)&(w.s<END)]
rides = [(a,b) for a,b in zip(M(w.s).values, M(w.e).values) if b-a>=20]
ins = pd.read_csv(f"{hd}/insulin.csv", names=cols, low_memory=False); ins=ins[ins.source=="Loop"]; ins["s"]=dst(ins.start.str[:19]); ins=ins[(ins.s>=START)&(ins.s<END)]
ins["t"]=M(ins.s); auto=ins.meta.fillna("").str.contains("AutomaticallyIssued=1")
bol = ins[(ins.reason==2)]; bt=bol.t.values; bu=bol.value.astype(float).values
man = ins[(ins.reason==2)&~auto]; mt = man.t.values
# lows (episodes)
lows=[]; last=-1e9
for t,v in zip(gt,gv):
    if v<70:
        if t-last>180: lows.append(t)
        last=t
lows=np.array(lows)
during=[]; after3=[]; after3_12=[]
for s,e in rides:
    during += [x for x in lows if s<=x<e+30]
    after3 += [x for x in lows if e+30<=x<e+180]
    after3_12 += [x for x in lows if e+180<=x<e+720]
print(f"rides={len(rides)}  low episodes={len(lows)}")
print(f"lows during ride or within 30 min after (before a Strava upload is likely): {len(set(during))}")
print(f"lows 30 min-3 h after ride end: {len(set(after3))}")
print(f"lows 3-12 h after ride end: {len(set(after3_12))}")
print(f"rides with a low during/within 30 min: {sum(any(s<=x<e+30 for x in lows) for s,e in rides)} of {len(rides)}")
# bolus IOB at ride start
iobs=[]; since=[]
for s,e in rides:
    m=(bt>s-360)&(bt<=s); iobs.append(float(np.sum(bu[m]*iob_fraction(s-bt[m]))))
    prev=mt[mt<=s]; since.append((s-prev[-1]) if len(prev) else np.nan)
iobs=np.array(iobs); since=np.array(since)
print(f"bolus IOB at ride start: median {np.median(iobs):.1f} U, rides with >2 U: {np.mean(iobs>2)*100:.0f}%")
print(f"minutes since last manual bolus at ride start: median {np.nanmedian(since):.0f}; within 2 h: {np.mean(since<120)*100:.0f}%")
bg0=[gv[np.searchsorted(gt,s)-1] for s,e in rides if np.searchsorted(gt,s)>0]
print(f"glucose at ride start: median {np.median(bg0):.0f}; below 120: {np.mean(np.array(bg0)<120)*100:.0f}%")
dur=[e-s for s,e in rides]; print(f"ride minutes median {np.median(dur):.0f}")
