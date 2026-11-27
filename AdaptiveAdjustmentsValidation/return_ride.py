import sys, numpy as np, pandas as pd
hd = sys.argv[1]; START, END = "2026-06-01", "2026-11-27"
def dst(x):
    x = pd.to_datetime(x); m = (x >= "2026-03-08 02:00") & (x < "2026-11-01 01:00")
    return x + pd.to_timedelta(m.astype(int), unit="h")
w = pd.read_csv(f"{hd}/workouts.csv", names=["start","end","type","dur","source"]); w["s"]=dst(w.start.str[:19]); w["e"]=dst(w.end.str[:19])
w = w[(w.s>=START)&(w.s<END)]; w["d"]=w.s.dt.date; w["m"]=w.s.dt.hour*60+w.s.dt.minute
days = sorted(set(pd.date_range(START, END, freq="D").date))
am = w[(w.m>=390)&(w.m<600)].groupby("d").m.min(); pm = w[(w.m>=900)&(w.m<1200)].groupby("d").m.min()
rows=[]
for d in days:
    rows.append(dict(d=d, am=d in am.index, pm=d in pm.index, pm_start=pm.get(d, np.nan), wkday=pd.Timestamp(d).weekday()<5))
D=pd.DataFrame(rows)
x=D[D.am]; print(f"days with morning ride: {len(x)}; also rode home (3-8pm): {x.pm.mean()*100:.0f}%")
y=D[~D.am & D.wkday]; print(f"weekdays without morning ride: {len(y)}; rode 3-8pm anyway: {y.pm.mean()*100:.0f}%")
st=x[x.pm].pm_start; print(f"return ride start: median {int(st.median())//60}:{int(st.median())%60:02d}, middle 50% {int(st.quantile(.25))//60}:{int(st.quantile(.25))%60:02d}-{int(st.quantile(.75))//60}:{int(st.quantile(.75))%60:02d}")
# rolling prediction: learn median return time from the previous 30 days of commute days; prep window = median-75 .. median+20
hit=0; n=0; covered=0
for i,r in D.iterrows():
    if not r.am: continue
    past = D[(D.d<r.d)&(D.d>=r.d-pd.Timedelta(days=45)) & D.am & D.pm]
    if len(past)<3: continue
    med = past.pm_start.median(); n+=1
    if r.pm:
        hit+=1
        if med-75 <= r.pm_start <= med+20: covered+=1
print(f"rolling check: {n} commute mornings; return ride happened {hit/n*100:.0f}%; ride started inside the prep window {covered/max(hit,1)*100:.0f}% of those")
# Same rule as the app: window = 25th percentile - 60 min .. 75th percentile + 15 min of recent return-ride starts
hit=0; n=0; covered=0; prep_minutes=[]
for i,r in D.iterrows():
    if not r.am: continue
    past = D[(D.d<r.d)&(D.d>=r.d-pd.Timedelta(days=45)) & D.am & D.pm]
    if len(past)<3: continue
    q25, q75 = past.pm_start.quantile(.25), past.pm_start.quantile(.75)
    lo, hi = q25-60, q75+15; n+=1; prep_minutes.append(hi-lo)
    if r.pm:
        hit+=1
        if lo <= r.pm_start <= hi: covered+=1
print(f"app rule: {n} commute mornings; ride home happened {hit/n*100:.0f}%; prep was running when it started {covered/max(hit,1)*100:.0f}%; prep window median {np.median(prep_minutes):.0f} min")
