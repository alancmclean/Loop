"""Run virtual patients through the synthetic world with plain Loop vs Loop + adaptive layer.

Usage: python3 -I run.py OUT.json [days] [learn_days] [patients...] [--variant name]
"""
import json, math, os, sys, time, warnings, bisect
warnings.filterwarnings("ignore")
import logging; logging.disable(logging.CRITICAL)
import numpy as np
import pandas as pd
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simglucose.patient.t1dpatient import T1DPatient, Action
import simglucose
from world import World, DAY
from controller import LoopController
import adaptive as A

QUEST = pd.read_csv(os.path.join(os.path.dirname(simglucose.__file__), "params", "Quest.csv")).set_index("Name")


def simulate(name, seed, days, learn_days, arm, variant=None):
    variant = variant or {}
    w = World(seed, days, alan=variant.get("alan", False))
    if variant.get("ideal"):
        w.needs[:] = 1.0; w.base_absorb[:] = 1.0; w.site_failures = []
        w.meals = [(t, g, round(g), True) for t, g, a, b in w.meals]
    for key in variant.get("world_off", []):
        if key == "exercise": w.workouts = []
    p = T1DPatient.withName(name, seed=seed)
    base_params = p._params.copy()
    basal = base_params.u2ss * base_params.BW / 6000 * 60   # U/h
    cr, isf = float(QUEST.loc[name, "CR"]) * variant.get("cr_mult", {}).get(name, 1.0), float(QUEST.loc[name, "CF"]) * variant.get("isf_mult", {}).get(name, 1.0)
    if variant.get("controller") == "oref":
        from controller_oref import OrefController
        ctl = OrefController(basal, isf, cr, **variant.get("oref", {}))
    else:
        ctl = LoopController(basal, isf, cr, max_bolus=variant.get("max_bolus", 10.0))
    rng = np.random.default_rng(seed + 999)
    noise = 0.0
    cfg = A.Config(**variant.get("cfg", {}))
    rules = A.Rules()
    for k, v in variant.get("rules", {}).items():
        setattr(rules, k, v)

    meals = {t: (g, ann, bol) for t, g, ann, bol in w.meals}
    sched_sites = set(w.site_changes)
    failures = {s: e for s, e in w.site_failures}
    failing = False
    sites = []          # observed site changes (pump events)
    cgm = []            # (t, bg)
    doses = []          # dicts for adaptive
    true_bg = []
    rate_uph, pending_bolus = basal, 0.0
    scale = 1.0
    factors = {}
    high_since = None
    alert_at = None
    last_alert = -10 ** 9
    autos = (1.0, 0)
    alerts = 0
    scales = []
    pending_change = None
    outcome_adj = {}
    brng = np.random.default_rng(seed + 4242)
    last_treat = last_extra = -10 ** 9
    tod = {}
    habits = []
    iob_hist = {}
    target_now = None
    feats = variant.get("features", set())
    bolus_cap_factor = 1.0

    # What the phone can actually know about workouts at time t:
    #   oracle  - the moment it starts (old, unrealistic)
    #   end     - only after it ends + upload delay (Apple Health / Strava)
    #   motion  - after ~10 min of motion-detected activity; end seen ~5 min after it ends;
    #             plus occasional false detections (e.g. bumpy car rides)
    ex_info = variant.get("ex_info", "oracle")
    upload_delay = variant.get("upload_delay", 30)
    fake = []
    if ex_info == "motion":
        frng = np.random.default_rng(seed + 77)
        for d in range(days):
            if frng.random() < 1 / 7:
                fs = d * DAY + int(frng.uniform(8, 19) * 60)
                fake.append((fs, fs + int(frng.uniform(12, 25))))
    def visible_workouts(t):
        out = []
        for s_, e_ in list(w.workouts) + fake:
            if ex_info == "end":
                if t >= e_ + upload_delay: out.append((s_, e_))
            elif ex_info == "motion":
                if t >= s_ + 10:
                    out.append((s_, e_ if t >= e_ + 5 else t + 1))
            else:
                if s_ <= t: out.append((s_, e_))
        return out

    def ctx_until(t):
        return dict(
            workouts=visible_workouts(t),
            nights=[x for x in w.nights if x[0] <= t],
            sites=[s for s in sites if s <= t],
            hrv=[x for x in w.hrv if x[0] <= t], rhr=[x for x in w.rhr if x[0] <= t], temp=[x for x in w.temp if x[0] <= t],
            logs=[x for x in w.logs() if x[0] <= t] if variant.get("logs", True) else [],
            use_physio=variant.get("physio", True))

    def change_site(t):
        nonlocal failing
        failing = False
        sites.append(t)

    n = days * DAY
    for t in range(n):
        if t in sched_sites:
            change_site(t)
        if t in failures:
            failing = True
        if pending_change is not None and t >= pending_change:
            change_site(t); pending_change = None

        # Patient physiology: hidden needs -> sensitivity.
        f = w.needs[t]
        prm = base_params.copy()
        prm["Vmx"] = base_params.Vmx / f
        prm["kp3"] = base_params.kp3 / f
        p._params = prm
        absorb = w.base_absorb[t] * (0.3 if failing else 1.0)

        cho = 0.0
        if t in meals:
            g, ann, bolused = meals[t]
            cho = g
            if bolused and ann:
                bg_now = cgm[-1][1] if cgm else 120
                isf_s, cr_s = isf / scale, cr / scale
                corr = max(0.0, (bg_now - 120) / isf_s - max(0.0, ctl.iob(t))) if bg_now > 150 else 0.0
                units = min(ann / cr_s + corr, 15.0)
                units = round(units / 0.05) * 0.05
                pending_bolus += units
                ctl.carbs.append((t, ann))
                ctl.record_delivery(t, units)
                doses.append(dict(t=t, end=t, units=units, bolus=True, manual=True))

        ins = rate_uph / 60 + pending_bolus
        pending_bolus = 0.0
        p.step(Action(CHO=cho, insulin=ins * absorb))

        if t % 5 == 0:
            g = p.observation.Gsub
            true_bg.append((t, g))
            noise = 0.7 * noise + rng.normal(0, 5)
            reading = float(np.clip(g + noise, 40, 400))
            cgm.append((t, round(reading)))

            # Adaptive layer (arm B, after learning period).
            if arm == "adaptive" and t >= learn_days * DAY:
                if t % DAY == 3 * 60 or not factors:
                    lstart = t - 30 * DAY
                    gl = [x for x in cgm if x[0] >= lstart]
                    dl = [d for d in doses if d["t"] >= lstart - 240]
                    mls = A.detect_meals(gl, dl, **variant.get("meal", {}))
                    bk = A.build_buckets(gl, dl, ctx_until(t), lstart, t, rules, mls, meal_after=variant.get("meal_after", 180), activity=variant.get("activity", False))
                    factors, eps = A.learn(bk, isf, priors=variant.get("priors"), min_episodes=variant.get("min_episodes", 3))
                    if variant.get("outcome") and t >= (learn_days + 3) * DAY:
                        since = [b for b in bk if b["start"] >= learn_days * DAY]
                        outcome_adj = A.outcome_adjust(since, outcome_adj)
                        for s_, a_ in outcome_adj.items():
                            factors[s_] = min(1.4, max(0.6, factors.get(s_, 1.0) + a_))
                    factors = factors or {"_": 1.0}
                if t % 60 == 0:
                    gl = [x for x in cgm if x[0] >= t - DAY - 60]
                    dl = [d for d in doses if d["t"] >= t - DAY - 240]
                    mls = A.detect_meals(gl, dl, **variant.get("meal", {}))
                    bk = A.build_buckets(gl, dl, ctx_until(t), t - DAY, t, rules, mls, meal_after=variant.get("meal_after", 180), activity=variant.get("activity", False))
                    autos = A.autosens(bk, t, isf, lambda x: ctl.scheduled_basal(x, 1.0))
                active = set(rules.active(t, ctx_until(t)))
                gl3 = [x for x in cgm if x[0] >= t - 180]
                dl3 = [d for d in doses if d["t"] >= t - 300]
                mls3 = A.detect_meals(gl3, dl3, **variant.get("meal", {}))
                ins2h = sum(d["units"] for d in doses if t - 120 <= d["t"] < t)
                suspect = A.site_failure(t, cgm[-40:], ins2h, basal * 2, mls3)
                if suspect and t - last_alert > 180:
                    last_alert = t; alerts += 1
                    if variant.get("act_on_alert", True):
                        pending_change = t + 30
                extra = 1.0
                target_now = None
                hod = int((t // 60) % 24)
                if t % DAY == 3 * 60:
                    if "ride_prep" in feats:
                        habits = A.ride_habits(visible_workouts(t), t)
                    if "tod" in feats:
                        tod = A.update_tod_profile(tod, [x for x in cgm if x[0] >= t - 7 * DAY])
                if "tod" in feats:
                    extra *= tod.get(hod, 1.0)
                past_w = visible_workouts(t)
                if "ride_prep" in feats and A.ride_prep_active(t, habits, past_w):
                    extra *= variant.get("prep_scale", 0.85)
                    if not variant.get("no_targets"): target_now = max(target_now or 0, 150)
                # Post-ride correction damping: during a ride no automatic boluses; for 3 h after, half size.
                bolus_cap_factor = 1.0
                if "post_cap" in feats:
                    for s_, e_ in past_w:
                        if s_ <= t <= e_ + 5: bolus_cap_factor = 0.0
                        elif e_ < t < e_ + 180: bolus_cap_factor = min(bolus_cap_factor, 0.5)
                if "post_target" in feats and A.post_exercise(t, past_w):
                    target_now = max(target_now or 0, 150)
                if "stack_guard" in feats:
                    iob = ctl.iob(t)
                    hist = iob_hist.get(hod, [])
                    typical = float(np.median(hist)) if len(hist) >= 30 else None
                    rate = (cgm[-1][1] - cgm[-3][1]) / 10 if len(cgm) >= 3 else 0
                    if typical is not None and iob > max(2.0, 1.8 * typical) and cgm[-1][1] < 150 and rate <= 0.5:
                        target_now = max(target_now or 0, 140)
                        extra *= 0.9
                scale = A.decide(cfg, active, factors, autos[0], cgm[-3:], suspect, scale, extra)
            scales.append(scale)

            # Everyone treats lows (not entered in Loop) and, alan-like, gives small no-carb corrections.
            if reading < 65 and t - last_treat >= 20:
                last_treat = t
                meals[t + 1] = (16.0, None, False)
            if variant.get("alan") and reading > 170 and len(cgm) >= 3 and cgm[-1][1] - cgm[-3][1] >= 10 \
                    and t - last_extra >= 60 and t % 30 == 0 and brng.random() < 0.35:
                last_extra = t
                u = round(brng.uniform(1.0, 2.0) / 0.05) * 0.05
                pending_bolus += u
                ctl.record_delivery(t, u)
                doses.append(dict(t=t, end=t, units=u, bolus=True, manual=True))

            # Plain user behaviour: change site after 3 h above 250.
            if reading > 250:
                high_since = high_since if high_since is not None else t
                if t - high_since >= 180 and pending_change is None:
                    pending_change = t + 15; high_since = None
            else:
                high_since = None

            if t % 5 == 0:
                iob_hist.setdefault(int((t // 60) % 24), []).append(ctl.iob(t))
                if len(iob_hist[int((t // 60) % 24)]) > 14 * 12:
                    iob_hist[int((t // 60) % 24)].pop(0)
            if hasattr(ctl, "update_tdd") and t % 60 == 0 and t >= DAY:
                d24 = sum(d["units"] for d in doses if d["t"] >= t - DAY)
                span = min(7, t // DAY)
                d7 = sum(d["units"] for d in doses if d["t"] >= t - span * DAY) / span
                ctl.update_tdd(d24, d7)
            rate_uph, bolus = ctl.step(t, cgm, scale, target_now)
            if arm == "adaptive" and t >= learn_days * DAY and "post_cap" in feats:
                bolus = round(bolus * bolus_cap_factor / 0.05) * 0.05
            sched = ctl.scheduled_basal(t, scale)
            # Net (vs scheduled, override-adjusted) insulin for the controller's model.
            ctl.record_delivery(t, (rate_uph - sched) * 5 / 60 + bolus)
            if bolus > 0:
                pending_bolus += bolus
                doses.append(dict(t=t, end=t, units=bolus, bolus=True, manual=False))
            doses.append(dict(t=t, end=t + 5, units=rate_uph * 5 / 60, bolus=False, manual=False))
            # the per-minute basal stays at rate_uph until next decision

    ev = np.array([g for tt, g in true_bg if tt >= learn_days * DAY])
    sc = np.array(scales[learn_days * DAY // 5:])
    return dict(
        patient=name, arm=arm, seed=seed,
        tir=float(((ev >= 70) & (ev <= 180)).mean()), tbr70=float((ev < 70).mean()), tbr54=float((ev < 54).mean()),
        tar180=float((ev > 180).mean()), tar250=float((ev > 250).mean()), mean=float(ev.mean()),
        cv=float(ev.std() / ev.mean()),
        low_hours=np.bincount(((np.array([tt for tt, g in true_bg if tt >= learn_days * DAY]) // 60) % 24)[ev < 70], minlength=24).tolist(), mean_scale=float(sc.mean()), alerts=alerts,
        factors={k: round(v, 3) for k, v in factors.items()})


def job(args):
    t0 = time.time()
    r = simulate(*args)
    r["secs"] = round(time.time() - t0)
    print(json.dumps(r), flush=True)
    return r


if __name__ == "__main__":
    from multiprocessing import Pool
    out = sys.argv[1]
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 50
    learn = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    variant_name = None
    pats = [a for a in sys.argv[4:] if not a.startswith("--")]
    if "--variant" in sys.argv:
        variant_name = sys.argv[sys.argv.index("--variant") + 1]
        pats = [a for a in pats if a != variant_name]
    from variants import VARIANTS
    variant = VARIANTS.get(variant_name, {})
    pats = pats or [f"adult#{i:03d}" for i in range(1, 7)]
    arms = variant.get("arms", ["loop", "adaptive"])
    jobs = [(pn, 100 + i, days, learn, arm, variant) for i, pn in enumerate(pats) for arm in arms]
    with Pool(2) as pool:
        res = pool.map(job, jobs)
    json.dump(res, open(out, "w"), indent=1)
