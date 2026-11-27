import sys, numpy as np, pandas as pd, collections
hd = sys.argv[1]; START, END = sys.argv[2], sys.argv[3]
cols = ["start","end","value","unit","source","reason","meta"]
def dst(x):
    x = pd.to_datetime(x); m = (x >= "2026-03-08 02:00") & (x < "2026-11-01 01:00")
    return x + pd.to_timedelta(m.astype(int), unit="h")
def load(n, src=None):
    d = pd.read_csv(f"{hd}/{n}.csv", names=cols, low_memory=False)
    d["s"] = dst(d.start.str[:19]); d["e"] = dst(d.end.str[:19])
    d = d[(d.s >= START) & (d.s < END)]
    return d[d.source == src] if src else d
steps = load("steps"); cyc = load("cycledist")
print("step sources:", steps.source.value_counts().head(4).to_dict())
print("cycling-distance sources:", cyc.source.value_counts().head(4).to_dict())
# Prefer one step source per day to avoid double counting (Watch vs iPhone): take max of per-source daily totals
steps["v"] = steps.value.astype(float); steps["d"] = steps.s.dt.date; steps["h"] = steps.s.dt.hour + steps.s.dt.minute/60
st_day = steps.groupby(["d","source"]).v.sum().groupby("d").max()
st_am = steps[steps.h < 10].groupby(["d","source"]).v.sum().groupby("d").max()
cyc["v"] = cyc.value.astype(float); cyc["d"] = cyc.s.dt.date; cyc["h"] = cyc.s.dt.hour + cyc.s.dt.minute/60
c_src = cyc.source.value_counts().index[0]
cy = cyc[cyc.source == c_src]
am_ride = cy[(cy.h >= 6.5) & (cy.h < 10)].groupby("d").v.sum()
pm_ride = cy[(cy.h >= 15) & (cy.h < 20)].groupby("d").v.sum()
day_ride = cy.groupby("d").v.sum()
w = pd.read_csv(f"{hd}/workouts.csv", names=["start","end","type","dur","source"]); w["s"]=dst(w.start.str[:19]); w=w[(w.s>=START)&(w.s<END)]
w["d"]=w.s.dt.date; w["h"]=w.s.dt.hour+w.s.dt.minute/60
wk_am = set(w[(w.h>=6.5)&(w.h<10)].d); wk_pm=set(w[(w.h>=15)&(w.h<20)].d)
g = load("glucose","Loop").drop_duplicates("s"); g["v"]=g.value.astype(float); g["d"]=g.s.dt.date; g["h"]=g.s.dt.hour
ins = load("insulin","Loop"); ins["u"]=ins.value.astype(float); ins["d"]=ins.s.dt.date
auto = ins.meta.fillna("").str.contains("AutomaticallyIssued=1"); ins["man"]=(ins.reason==2)&~auto
rows=[]
for d, gg in g.groupby("d"):
    dt = pd.Timestamp(d)
    if dt.weekday() >= 5 or len(gg) < 250: continue
    am = am_ride.get(d, 0) > 1000 or d in wk_am     # metres
    pm = pm_ride.get(d, 0) > 1000 or d in wk_pm
    rows.append(dict(d=d, dow=dt.day_name()[:3], steps=st_day.get(d, np.nan), steps_am=st_am.get(d, np.nan),
        ride_km=day_ride.get(d, 0)/1000, am=am, pm=pm,
        tdd=ins[ins.d==d].u.sum(), manual=ins[(ins.d==d)&ins.man].u.sum(),
        mean=gg.v.mean(), tir=((gg.v>=70)&(gg.v<=180)).mean()*100, low=(gg.v<70).mean()*100, high=(gg.v>180).mean()*100,
        high_9_17=(gg[(gg.h>=9)&(gg.h<17)].v>180).mean()*100, low_9_17=(gg[(gg.h>=9)&(gg.h<17)].v<70).mean()*100))
D = pd.DataFrame(rows)
def kind(r):
    if r.am and r.pm: return "commute (rode both ways)"
    if r.ride_km < 1 and (np.isnan(r.steps) or r.steps < 6000): return "home, sedentary"
    if r.ride_km < 1: return "home/other, active"
    return "one ride"
D["kind"] = D.apply(kind, axis=1)
print(f"\nweekdays analysed: {len(D)}  ({START} to {END})")
agg = D.groupby("kind").agg(days=("d","count"), steps=("steps","median"), ride_km=("ride_km","median"), tdd=("tdd","median"),
    manual=("manual","median"), mean=("mean","mean"), tir=("tir","mean"), low=("low","mean"), high=("high","mean"),
    high_9_17=("high_9_17","mean"), low_9_17=("low_9_17","mean")).round(1)
print(agg.to_string())
print("\nby weekday (share of commute days):")
print(D.groupby("dow").kind.apply(lambda x: f"{(x=='commute (rode both ways)').mean()*100:.0f}% commute, {(x=='home, sedentary').mean()*100:.0f}% home-sedentary, n={len(x)}").to_string())
# Can we tell by 10am? steps before 10 + morning ride
D["am_signal"] = D.am
print("\nmorning ride predicts commute day:", f"{(D[D.am].kind=='commute (rode both ways)').mean()*100:.0f}% of mornings with a ride")
hs = D[D.kind=="home, sedentary"].steps_am; cs = D[D.kind.str.startswith("commute")].steps_am
print(f"steps before 10am: home-sedentary median {hs.median():.0f}, commute median {cs.median():.0f}")

# ---- Day-level insulin need (daytime 8:00-20:00), relative to "no ride, active" days
ISF = 32.0
def need(d):
    gg = g[(g.d == d) & (g.h >= 8) & (g.h < 20)]
    ii = ins[(ins.d == d) & (ins.s.dt.hour >= 8) & (ins.s.dt.hour < 20)]
    if len(gg) < 100: return np.nan
    return ii.u.sum() + (gg.v.mean() - 120) / ISF * 12 / 3
D["need"] = D.d.map(need)
ref = D[D.kind == "home/other, active"].need.median()
print("\ndaytime need vs active no-ride days:", (D.groupby("kind").need.median() / ref).round(3).to_dict())

# ---- Hour-level: movement in the last 2 h vs glucose in the next 3 h (all days, 8:00-20:00)
ph = steps[steps.source == steps.source.value_counts().index[0]].copy()
ph["hr"] = ph.s.dt.floor("h")
sph = ph.groupby("hr").v.sum()
gg = g.copy(); gg["hr"] = gg.s.dt.floor("h")
gh = gg.groupby("hr").v.agg(["mean", lambda x: (x < 70).mean(), lambda x: (x > 180).mean()]); gh.columns = ["mean", "low", "high"]
rows = []
for hr in gh.index:
    if not (8 <= hr.hour < 20): continue
    prev2 = sph.get(hr - pd.Timedelta(hours=1), 0) + sph.get(hr - pd.Timedelta(hours=2), 0)
    nxt = gh.loc[[x for x in (hr, hr + pd.Timedelta(hours=1), hr + pd.Timedelta(hours=2)) if x in gh.index]]
    rows.append(dict(steps2h=prev2, mean=nxt["mean"].mean(), low=nxt.low.mean() * 100, high=nxt.high.mean() * 100))
H = pd.DataFrame(rows)
H["bin"] = pd.cut(H.steps2h, [-1, 200, 1000, 3000, 1e9], labels=["<200", "200-1k", "1k-3k", ">3k"])
print("\nnext-3h glucose by steps in previous 2 h (8am-8pm):")
print(H.groupby("bin", observed=True).agg(hours=("mean", "count"), mean=("mean", "mean"), low=("low", "mean"), high=("high", "mean")).round(1).to_string())

# ---- Predictability without fixed days: recency-weighted weekday prior + morning evidence
D = D.sort_values("d").reset_index(drop=True)
D["sed"] = (D.kind == "home, sedentary").astype(int)
hits = []
for i, r in D.iterrows():
    past = D[(D.d < r.d) & (D.dow == r.dow)].tail(6)
    if len(past) < 3: continue
    wts = 0.8 ** np.arange(len(past))[::-1]
    prior = (np.dot(past.sed, wts) + 0.5) / (wts.sum() + 1)
    # morning evidence by 10:00: a ride -> not sedentary; low steps -> more likely sedentary
    p = prior
    if r.am: p = 0.05
    elif not np.isnan(r.steps_am): p = min(0.95, p * (1.6 if r.steps_am < 2500 else 0.6))
    hits.append(dict(prior=prior, p10=p, truth=r.sed))
P = pd.DataFrame(hits)
def acc(col): return ((P[col] > 0.5) == (P.truth == 1)).mean() * 100
print(f"\nsedentary-day prediction (n={len(P)}): weekday-prior only {acc('prior'):.0f}% correct; by 10am with movement {acc('p10'):.0f}% correct; always-guess-not-sedentary {(P.truth == 0).mean() * 100:.0f}%")
