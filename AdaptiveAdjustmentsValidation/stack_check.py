import sys, numpy as np, pandas as pd
hd=sys.argv[1]; END=pd.Timestamp(sys.argv[2]); START=END-pd.Timedelta(days=28)
cols=["start","end","value","unit","source","reason","meta"]
g=pd.read_csv(f"{hd}/glucose.csv",names=cols); g=g[g.source=="Loop"]; g["t"]=pd.to_datetime(g.start.str[:19]); g=g[(g.t>=START-pd.Timedelta(days=1))&(g.t<END+pd.Timedelta(hours=6))].drop_duplicates("t").sort_values("t")
gt=g.t.values.astype("datetime64[m]").astype(float); gv=g.value.astype(float).values
ins=pd.read_csv(f"{hd}/insulin.csv",names=cols,low_memory=False); ins=ins[ins.source=="Loop"]; ins["t"]=pd.to_datetime(ins.start.str[:19]); ins["te"]=pd.to_datetime(ins.end.str[:19])
ins=ins[(ins.t>=START-pd.Timedelta(hours=8))&(ins.t<END)]; ins["u"]=ins.value.astype(float)
auto=ins.meta.fillna("").str.contains("AutomaticallyIssued=1"); bol=ins[ins.reason==2]; man=ins[(ins.reason==2)&~auto]
bt=bol.t.values.astype("datetime64[m]").astype(float); bu=bol.u.values
peak,dur,delay=75.,360.,10.
tau=peak*(1-peak/dur)/(1-2*peak/dur); a=2*tau/dur; S=1/(1-a+(1+a)*np.exp(-dur/tau))
def frac(t):
    t=np.asarray(t)-delay; out=1-S*(1-a)*((t*t/(tau*dur*(1-a))-t/tau-1)*np.exp(-t/tau)+1)
    return np.where(t<=0,1,np.where(t>=dur,0,out))
def iob(x, excl=None):
    el=x-bt; m=(el>0)&(el<dur+delay+1)
    return float((bu[m]*frac(el[m])).sum())
rows=[]
for _,b in man[(man.t>=START)&(man.t<END)].iterrows():
    x=np.datetime64(b.t,"m").astype(float); before=iob(x-0.5)
    i=np.searchsorted(gt,x)-1
    if i<0 or x-gt[i]>15: continue
    gnow=gv[i]; trend=(gv[i]-gv[max(i-3,0)])/max(gt[i]-gt[max(i-3,0)],1)
    fut=(gt>x)&(gt<=x+240); low=bool((gv[fut]<70).any())
    rows.append((before,gnow,trend,low,b.u))
r=pd.DataFrame(rows,columns=["iob","g","trend","low","u"])
print(len(r),"manual boluses in 28 days;", f"{len(r)/28:.1f}/day")
r["band"]=pd.cut(r.iob,[-1,2,4,6,99],labels=["<2","2-4","4-6",">6"])
print(r.groupby("band",observed=True).agg(n=("low","size"),low4h=("low","mean"),g=("g","median")).round(2))
r["gb"]=pd.cut(r.g,[0,140,180,250,999],labels=["<140","140-180","180-250",">250"])
print(r.groupby(["gb"],observed=True).agg(n=("low","size"),low4h=("low","mean"),iob=("iob","median")).round(2))
hi=r[r.g>180]; print("boluses when >180: n",len(hi)," low rate by IOB>=4:",hi[hi.iob>=4].low.mean().round(2),"n",(hi.iob>=4).sum()," IOB<4:",hi[hi.iob<4].low.mean().round(2))
fl=r[(r.trend<=-1)]; print("boluses while falling ≥1/min: n",len(fl),"low rate",fl.low.mean().round(2))
for s_ in ["2026-11-20 09:42","2026-11-20 16:22","2026-11-21 14:04","2026-11-23 09:15","2026-11-24 10:42"]:
    x=np.datetime64(pd.Timestamp(s_),"m").astype(float); print(s_, round(iob(x-0.5),1))
