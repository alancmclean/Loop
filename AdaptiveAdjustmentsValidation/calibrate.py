import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from multiprocessing import Pool
from run import simulate
pats=[f"adult#{i:03d}" for i in range(1,7)]
grid=[(c,m) for c in (1.0,1.25) for m in (1.0,1.5,2.0,3.0)]
def j(a):
    pn,c,m=a
    r=simulate(pn,100,3,1,"loop",{"ideal":True,"isf_mult":{pn:m},"cr_mult":{pn:c}})
    return (pn,c,m,round(r["tir"],3),round(r["tbr70"],3),round(r["mean"]))
if __name__=="__main__":
    with Pool(2) as p: res=p.map(j,[(pn,c,m) for pn in pats for c,m in grid])
    for r in res: print(r)
    json.dump(res,open("/tmp/calib.json","w"))
