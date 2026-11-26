"""Python port of the Swift adaptive-override logic (AdaptiveOverrideCore/Learning), in minutes.
Kept structurally identical so findings here map back to the Swift code.
"""
import numpy as np

H = 60
DAY = 1440


def median(xs):
    return float(np.median(xs)) if len(xs) else None


class Rules:
    min_workout = 20
    ex_early = 3 * H
    ex_late = 12 * H
    short_sleep = 6 * H
    short_sleep_window = 8 * H
    new_site = 12 * H
    old_site = 48 * H
    alcohol = (2 * H, 16 * H)
    illness = 24 * H
    baseline_days = 30

    def deviates(self, samples, t, low, min_abs, sd_mult, min_rel=0.0):
        rs = t - DAY
        bs = rs - self.baseline_days * DAY
        recent = [v for d, v in samples if rs <= d < t]
        base = [v for d, v in samples if bs <= d < rs]
        if not recent or len(base) < 7:
            return False
        r = np.mean(recent); m = np.mean(base); sd = np.std(base, ddof=1)
        th = max(min_abs, sd_mult * sd, min_rel * abs(m))
        return r < m - th if low else r > m + th

    def active(self, t, ctx):
        out = {}
        for s, e in ctx["workouts"]:
            if e - s < self.min_workout:
                continue
            since = t - e
            if t >= s and since < self.ex_early:
                out["exerciseEarly"] = s
            elif self.ex_early <= since < self.ex_late:
                out["exerciseLate"] = s
        for wake, asleep in ctx["nights"]:
            if asleep < self.short_sleep and 0 <= t - wake < self.short_sleep_window:
                out["shortSleep"] = wake
        prior = [c for c in ctx["sites"] if c <= t]
        if prior:
            age = t - prior[-1]
            if age < self.new_site:
                out["siteNew"] = prior[-1]
            elif age >= self.old_site:
                out["siteOld"] = prior[-1]
        day = t // DAY
        if ctx.get("use_physio", True):
            if self.deviates(ctx["hrv"], t, True, 3, 1.0, 0.15):
                out["lowHRV"] = day
            if self.deviates(ctx["rhr"], t, False, 4, 1.5):
                out["elevatedRestingHR"] = day
            if self.deviates(ctx["temp"], t, False, 0.5, 2.0):
                out["elevatedTemperature"] = day
        for lt, kind in ctx["logs"]:
            since = t - lt
            if kind == "alcohol" and self.alcohol[0] <= since <= self.alcohol[1]:
                out["alcohol"] = lt
            if kind == "illness" and 0 <= since < self.illness:
                out["illness"] = lt
        if getattr(self, "use_weekend", True) and (t // DAY) % 7 in (5, 6):
            out["weekend"] = day
        return out


CONTEXT = {"weekend"}


def detect_meals(glucose, doses, min_rise=40, window=60, bolus_max_bg=150, min_bolus=1.0, dedupe=90):
    """glucose: list (t, bg) sorted; doses: list of dict(t, units, bolus, manual)."""
    starts = []
    i = 0
    n = len(glucose)
    while i < n:
        j = i + 1
        found = None
        while j < n and glucose[j][0] - glucose[i][0] <= window:
            if glucose[j][1] - glucose[i][1] >= min_rise:
                found = j
                break
            j += 1
        if found is not None:
            starts.append(glucose[i][0])
            k = found
            while k + 1 < n and glucose[k + 1][1] >= glucose[k][1]:
                k += 1
            i = k + 1
        else:
            i += 1
    gt = [g[0] for g in glucose]
    import bisect
    for d in doses:
        if d["manual"] and d["bolus"] and d["units"] >= min_bolus:
            idx = bisect.bisect_right(gt, d["t"]) - 1
            if idx >= 0 and d["t"] - gt[idx] < 15 and glucose[idx][1] <= bolus_max_bg:
                starts.append(d["t"])
    out = []
    for s in sorted(starts):
        if out and s - out[-1] < dedupe:
            continue
        out.append(s)
    return out


def near_meal(t, meals, before=30, after=180):
    import bisect
    i = bisect.bisect_right(meals, t + before)
    return i > 0 and t - meals[i - 1] < after


def build_buckets(glucose, doses, ctx, start, end, rules, meals, meal_after=180, activity=False):
    """Hourly buckets. glucose sorted list; doses list of dicts with t, end, units, bolus, manual.
    activity=True: 'insulin' is insulin *acting* in the hour (exponential model), not delivered."""
    import bisect
    if activity:
        from controller import iob_fraction
        dt_arr = np.array([(d["t"] + d.get("end", d["t"])) / 2 for d in doses]) if doses else np.zeros(0)
        du_arr = np.array([d["units"] for d in doses]) if doses else np.zeros(0)
    gt = np.array([g[0] for g in glucose]); gv = np.array([g[1] for g in glucose])
    manual_t = sorted(d["t"] for d in doses if d["manual"] and d["bolus"])
    # insulin per minute array for speed
    span = end - start
    ins = np.zeros(span + 1)
    for d in doses:
        a, b = d["t"], d.get("end", d["t"])
        if b - a <= 1:
            if start <= a < end:
                ins[int(a - start)] += d["units"]
        else:
            lo, hi = max(a, start), min(b, end)
            if hi > lo:
                ins[int(lo - start):int(hi - start)] += d["units"] / (b - a)
    buckets = []
    hs = start - start % H
    while hs + H <= end:
        he = hs + H
        i0, i1 = np.searchsorted(gt, hs), np.searchsorted(gt, he)
        vals = gv[i0:i1]
        if len(vals) >= 6:
            mid = hs + 30
            k0 = bisect.bisect_left(manual_t, hs - 3 * H)
            recent_bolus = k0 < len(manual_t) and manual_t[k0] < he
            buckets.append(dict(
                start=hs, hour=(hs // H) % 24, mean=float(vals.mean()), first=float(vals[0]), last=float(vals[-1]),
                low=float((vals < 70).mean()), inrange=float(((vals >= 70) & (vals <= 180)).mean()),
                insulin=(float(np.sum(du_arr[m] * (iob_fraction(hs - dt_arr[m]) - iob_fraction(he - dt_arr[m]))))
                         if activity and (m := (dt_arr > hs - 400) & (dt_arr < he)).any() else
                         float(ins[max(0, hs - start):max(0, he - start)].sum())),
                signals=rules.active(mid, ctx), near_meal=near_meal(mid, meals, after=meal_after),
                recent_bolus=recent_bolus))
        hs = he
    return buckets


def behavioural(b):
    return [s for s in b["signals"] if s not in CONTEXT and not s.startswith("siteLocation.")]


def is_fasting(b):
    return not b["near_meal"] and not b["recent_bolus"] and not behavioural(b)


def learn(buckets, isf, min_episodes=3, prior=5.0, lo=0.6, hi=1.4, priors=None, relative=False):
    usable = [b for b in buckets if not b["near_meal"] and not b["recent_bolus"]]
    signals = sorted({s for b in usable for s in b["signals"]})
    factors, episodes = {}, {}
    for sig in signals:
        is_ctx = sig in CONTEXT
        bg, bi = {}, {}
        for b in usable:
            if not behavioural(b) and (not is_ctx or sig not in b["signals"]):
                bg.setdefault(b["hour"], []).append(b["mean"])
                bi.setdefault(b["hour"], []).append(b["insulin"])
        est, eps = [], set()
        for b in usable:
            if sig not in b["signals"]:
                continue
            if [s for s in behavioural(b) if s != sig]:
                continue
            g, i = bg.get(b["hour"]), bi.get(b["hour"])
            if not g or not i or len(g) < 3 or len(i) < 3:
                continue
            base_i = np.mean(i)
            if base_i < 0.05:
                continue
            gterm = (b["mean"] - np.mean(g)) / isf / 3.0 / base_i
            est.append(b["insulin"] / base_i + gterm)
            eps.add(b["signals"][sig])
        n = len(eps)
        episodes[sig] = n
        p0 = (priors or {}).get(sig, 1.0)
        if n >= min_episodes and est:
            w = n / (n + prior)
            f = p0 + (median(est) - p0) * w
            factors[sig] = min(max(f, lo), hi)
        elif p0 != 1.0:
            factors[sig] = p0
    for sig, p0 in (priors or {}).items():
        factors.setdefault(sig, p0)
    return factors, episodes


def outcome_adjust(buckets, adj, step_down=0.05, step_up=0.03, low_margin=0.02, high_margin=15, min_hours=8, limit=0.25):
    """Outcome feedback: hours with a signal vs ordinary hours at the same time of day,
    using glucose outcomes only (meal hours included, carbs never used)."""
    base = {}
    for b in buckets:
        if not behavioural(b):
            base.setdefault(b["hour"], []).append(b)
    by_sig = {}
    for b in buckets:
        for s in behavioural(b):
            by_sig.setdefault(s, []).append(b)
    for s, bs in by_sig.items():
        pairs = [(b, base[b["hour"]]) for b in bs if len(base.get(b["hour"], [])) >= 3]
        if len(pairs) < min_hours:
            continue
        low = np.mean([b["low"] for b, _ in pairs]); blow = np.mean([np.mean([x["low"] for x in bl]) for _, bl in pairs])
        mean = np.mean([b["mean"] for b, _ in pairs]); bmean = np.mean([np.mean([x["mean"] for x in bl]) for _, bl in pairs])
        a = adj.get(s, 0.0)
        if low > blow + low_margin:
            a -= step_down
        elif mean > bmean + high_margin and low <= blow:
            a += step_up
        adj[s] = max(-limit, min(limit, a))
    return adj


def autosens(buckets, now, isf, basal_at, min_hours=4, prior=6.0, lookback=DAY):
    ratios = []
    for b in buckets:
        if b["start"] >= now - lookback and is_fasting(b):
            r = basal_at(b["start"] + 30)
            if r >= 0.05:
                ratios.append((b["insulin"] + (b["last"] - b["first"]) / isf) / r)
    if len(ratios) < min_hours:
        return 1.0, len(ratios)
    w = len(ratios) / (len(ratios) + prior)
    return 1.0 + (median(ratios) - 1.0) * w, len(ratios)


def site_failure(now, glucose, doses_ins_2h, sched_2h, meals, min_bg=200, ratio=1.5, max_drop=10):
    g = [x for x in glucose if x[0] >= now - 150]
    if not g or now - g[-1][0] >= 15 or g[-1][1] < min_bg:
        return False
    earlier = [x for x in g if x[0] <= now - 120]
    if not earlier:
        return False
    e = earlier[-1]
    if any(now - 180 <= m <= now for m in meals):
        return False
    if g[-1][1] < e[1] - max_drop:
        return False
    if not all(x[1] >= min_bg - 30 for x in g if x[0] >= e[0]):
        return False
    return sched_2h > 0 and doses_ins_2h >= ratio * sched_2h


class Config:
    def __init__(self, **kw):
        self.min_scale, self.max_scale = 0.8, 1.2
        self.abs_min, self.abs_max = 0.7, 1.3
        self.max_step = 0.05
        self.low_bg = 90
        self.falling = -2.0
        self.deadband = 0.03
        self.use_autosens = True
        self.autosens_range = (0.85, 1.15)
        self.disabled = set()
        self.__dict__.update(kw)


def decide(cfg, active, factors, autos, glucose_recent, site_suspect, current, extra=1.0):
    """Returns new scale (1.0 = none). extra: additional multiplier (time-of-day profile, ride prep)."""
    latest = glucose_recent[-1]
    rate = None
    if len(glucose_recent) >= 2:
        p = glucose_recent[-2]
        mins = latest[0] - p[0]
        if 4 <= mins <= 16:
            rate = (latest[1] - p[1]) / mins
    target = 1.0
    for s in sorted(active):
        if s in cfg.disabled:
            continue
        f = factors.get(s, 1.0)
        if abs(f - 1) >= 0.01:
            target *= f
    if cfg.use_autosens:
        a = min(max(autos, cfg.autosens_range[0]), cfg.autosens_range[1])
        if abs(a - 1) >= 0.01:
            target *= a
    target *= extra
    lo = min(max(cfg.min_scale, cfg.abs_min), 1.0); hi = max(min(cfg.max_scale, cfg.abs_max), 1.0)
    target = min(max(target, lo), hi)
    low_fall = latest[1] < cfg.low_bg or (rate is not None and rate <= cfg.falling)
    if low_fall and target > 1:
        target = 1.0
    if site_suspect and target > 1:
        target = 1.0
    cur = current
    down = cfg.max_step * 2 if low_fall else cfg.max_step
    stepped = min(max(target, cur - down), cur + cfg.max_step)
    if abs(stepped - 1) < cfg.deadband and abs(target - 1) < cfg.deadband:
        return 1.0
    return round(stepped, 2)


# ---------- New strategies ----------

def ride_habits(workouts, now, days=28, slot=30, min_freq=0.35, min_count=4):
    """Usual workout start slots by day type (weekday/weekend), from the last `days` days."""
    start = now - days * DAY
    counts = {}
    ndays = {False: 0, True: 0}
    for d in range(int(start // DAY), int(now // DAY)):
        ndays[(d % 7) in (5, 6)] += 1
    for s_, e_ in workouts:
        if start <= s_ < now and e_ - s_ >= 20:
            wk = ((s_ // DAY) % 7) in (5, 6)
            sl = int((s_ % DAY) // slot)
            counts.setdefault((wk, sl), set()).add(s_ // DAY)
    cands = []
    for (wk, sl), dset in counts.items():
        # merge neighbours: count days with a start in this slot or adjacent ones
        days_ = set(dset) | counts.get((wk, sl - 1), set()) | counts.get((wk, sl + 1), set())
        f = len(days_) / max(1, ndays[wk])
        if len(days_) >= min_count and f >= min_freq:
            cands.append((f, wk, sl))
    cands.sort(reverse=True)
    kept = []
    for f, wk, sl in cands:
        if not any(k[0] == wk and abs(k[1] - sl) <= 2 for k in kept):
            kept.append((wk, sl, f))
    return [(wk, sl * slot, f) for wk, sl, f in kept]


def ride_prep_active(t, habits, workouts, lead=75, after=30):
    """Before a usual workout time, if no workout has started yet today around it."""
    wk = ((t // DAY) % 7) in (5, 6)
    tod = t % DAY
    for hwk, minute, f in habits:
        if hwk != wk:
            continue
        if minute - lead <= tod <= minute + after:
            slot_abs = (t // DAY) * DAY + minute
            if not any(slot_abs - 120 <= s_ <= t for s_, e_ in workouts):
                return True
    return False


def post_exercise(t, workouts, window=180):
    return any(s_ <= t and t - e_ < window for s_, e_ in workouts)


def update_tod_profile(profile, cgm_recent, step_down=0.02, step_up=0.015, low_th=0.04, high_th=0.20, lo=0.7, hi=1.15, lead=(1, 2)):
    """Outcome-based time-of-day profile (glucose only). Lows at hour h -> less insulin 1–2 h earlier."""
    byh = {}
    for tt, v in cgm_recent:
        byh.setdefault(int((tt // 60) % 24), []).append(v)
    for h, vals in byh.items():
        v = np.array(vals)
        if len(v) < 36:
            continue
        low = (v < 70).mean(); high = (v > 180).mean()
        for L in lead:
            k = (h - L) % 24
            if low > low_th:
                profile[k] = max(lo, profile.get(k, 1.0) - step_down)
            elif high > high_th and low < low_th / 2:
                profile[k] = min(hi, profile.get(k, 1.0) + step_up)
    return profile
