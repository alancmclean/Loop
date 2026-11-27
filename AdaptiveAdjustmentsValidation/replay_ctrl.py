"""On real history: what would each controller recommend before highs and lows, vs what was given?
Usage: python3 -I replay_ctrl.py analyze_real.py HD SIM START END ISF CR
"""
import sys, json, numpy as np
SRC = sys.argv[1]; sys.argv = sys.argv[1:]
ISF_IN, CR_IN = float(sys.argv[5]), float(sys.argv[6])
exec(open(SRC).read().split("# ---- Overview")[0])
from controller import LoopController
from controller_oref import OrefController
ISF, CR = ISF_IN, CR_IN
DAYM = 1440
gt = np.array([t for t, _ in glucose]); gv = np.array([v for _, v in glucose], float)
ins_t = ins.t.values.astype(float); ins_te = ins.te.values.astype(float); ins_u = ins.value.values.astype(float)
ins_sched = ins.sched.values; ins_bas = (ins.reason == 1).values
c_t = carbs.t.values.astype(float); c_g = carbs.g.values.astype(float)

ins_manual = ((ins.reason == 2) & ~ins.auto).values
def delivered(a, b, manual=None):
    m = (ins_t >= a) & (ins_t < b)
    if manual is not None: m &= (ins_manual == manual)
    return float(ins_u[m].sum())

def state(ctl, t):
    """Load real history into a controller at time t."""
    m = (ins_t >= t - 380) & (ins_t < t)
    net = []
    for tt, te, u, sc, isb in zip(ins_t[m], ins_te[m], ins_u[m], ins_sched[m], ins_bas[m]):
        if isb:
            s_ = basal_at(tt) if np.isnan(sc) else sc
            net.append(((tt + te) / 2, u - s_ * (te - tt) / 60))
        else:
            net.append((tt, u))
    ctl.net_doses = net
    mc = (c_t >= t - 240) & (c_t <= t)
    ctl.carbs = list(zip(c_t[mc], c_g[mc]))
    b = basal_at(t); ctl.basal = b; ctl.max_basal = 4 * b
    if hasattr(ctl, "pred_hist"): ctl.pred_hist = {}
    i1 = np.searchsorted(gt, t, side="right"); i0 = np.searchsorted(gt, t - 120)
    return list(zip(gt[i0:i1].tolist(), gv[i0:i1].tolist()))

tdd_day = ins.groupby(ins.s.dt.date).value.sum()
tdd_med = float(tdd_day.median())

# Layer (v5-style) inputs: time-of-day profile after one week of updates, post-exercise target.
prof = {}
for d in range(int(t1 // DAYM) - 7, int(t1 // DAYM)):
    prof = A.update_tod_profile(prof, [x for x in glucose if d * DAYM - 7 * DAYM <= x[0] < d * DAYM])
def layer(t):
    scale = prof.get(int((t // 60) % 24), 1.0)
    for s_, e_ in workouts:
        if 0 <= t - e_ < 180: return scale * 0.9, 150.0
        if 180 <= t - e_ < 720: scale *= 0.9
    return max(0.8, min(1.2, scale)), None

def recommend(kind, t):
    if kind == "loop":
        c = LoopController(1.0, ISF, CR); h = state(c, t); r, b = c.step(t, h, 1.0)
    elif kind == "loop+layer":
        c = LoopController(1.0, ISF, CR); h = state(c, t); sc, tg = layer(t); r, b = c.step(t, h, sc, tg)
    else:
        c = OrefController(1.0, ISF, CR, avg_meal_g=50); c.update_tdd(tdd_med, tdd_med); h = state(c, t)
        c.max_iob = 50 / CR + 3 * c.basal
        r, b = c.step(t, h, 1.0)
    return r * 5 / 60 + b

def window(t_end, a, b, step=5):
    """One decision at t_end-a: insulin each controller would give over the next 30 min if it held
    that decision (temp basal x 0.5 h + any automatic bolus), vs Loop's actual automatic insulin then."""
    t = int(t_end - a)
    i1 = np.searchsorted(gt, t, side="right")
    if i1 < 4 or t - gt[i1 - 1] > 15:
        return None
    out = {}
    for k in ("loop", "loop+layer", "trio-like"):
        out[k] = recommend30(k, t)
    out["actual_automatic"] = delivered(t, t + 30, manual=False)
    out["actual_manual_boluses"] = delivered(t, t + 30, manual=True)
    return out

def recommend30(kind, t):
    if kind == "loop":
        c = LoopController(1.0, ISF, CR); h = state(c, t); r, b = c.step(t, h, 1.0)
    elif kind == "loop+layer":
        c = LoopController(1.0, ISF, CR); h = state(c, t); sc, tg = layer(t); r, b = c.step(t, h, sc, tg)
    else:
        c = OrefController(1.0, ISF, CR, avg_meal_g=50); c.update_tdd(tdd_med, tdd_med); h = state(c, t)
        c.max_iob = 50 / CR + 3 * c.basal
        r, b = c.step(t, h, 1.0)
    return r * 0.5 + b * (1 if kind != "trio-like" else 3)   # SMBs repeat ~every 5 min; ~3 in 30 min at most

# Events
lows = []; last = -1e9
for t, v in glucose:
    if v < 70:
        if t - last > 180: lows.append(t)
        last = t
rises = []; above = False; lastr = -1e9
for t, v in glucose:
    if v > 180 and not above and t - lastr > 240:
        rises.append(t); lastr = t
    above = v > 180
rng = np.random.default_rng(3)
def agg(events, a, b, n=80):
    ev = list(rng.choice(events, min(n, len(events)), replace=False)) if len(events) > n else events
    rows = [r for r in (window(t, a, b) for t in ev) if r is not None]
    return {k: round(float(np.mean([r[k] for r in rows])), 2) for k in rows[0]}, len(ev)

R = {"assumed_isf": ISF, "assumed_cr": CR, "tdd_median": round(tdd_med, 1)}
R["decision 30 min before crossing 180"], R["n_highs"] = agg(rises, 30, 0, n=300)
R["decision 60 min before going <70"], R["n_lows"] = agg(lows, 60, 0, n=300)
randt = [t for t in rng.choice(gt, 300)]
R["random times"], _ = agg(randt, 0, 0)
print(json.dumps(R, indent=1))
