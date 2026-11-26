"""A simplified Loop-style controller, written from Loop's published behaviour:
exponential insulin model (peak 75 min, 6 h), linear carb absorption from carb
entries, retrospective correction, temp basal plus partial automatic bolus,
suspend on predicted low. Scaled by an override factor exactly like Loop's
insulinNeedsScaleFactor (basal x f, ISF / f, CR / f).
"""
import math
import numpy as np

TD, TP, DELAY = 360.0, 75.0, 10.0
_tau = TP * (1 - TP / TD) / (1 - 2 * TP / TD)
_a = 2 * _tau / TD
_S = 1 / (1 - _a + (1 + _a) * math.exp(-TD / _tau))


def iob_fraction(t):
    """Fraction of a dose still on board t minutes after delivery."""
    t = np.asarray(t, dtype=float) - DELAY
    out = np.where(t <= 0, 1.0, 0.0)
    m = (t > 0) & (t < TD)
    tm = t[m]
    out[m] = 1 - _S * (1 - _a) * ((tm ** 2 / (_tau * TD * (1 - _a)) - tm / _tau - 1) * np.exp(-tm / _tau) + 1)
    return out


class LoopController:
    def __init__(self, basal_uph, isf, cr, target=105, suspend=70, max_basal_mult=4.0, max_bolus=6.0,
                 autobolus_fraction=0.4, carb_absorption=180):
        self.basal, self.isf, self.cr = basal_uph, isf, cr
        self.target, self.suspend = target, suspend
        self.max_basal = basal_uph * max_basal_mult
        self.max_bolus = max_bolus
        self.autobolus_fraction = autobolus_fraction
        self.carb_abs = carb_absorption
        self.net_doses = []   # (t, units) net of scheduled basal, 5-min chunks and boluses
        self.carbs = []       # (t, grams)
        self.pred_hist = {}   # t -> predicted BG at t+30 (for retrospective correction)
        self.dawn_basal = None  # optional hourly basal profile (list of 24)

    def scheduled_basal(self, t, scale):
        b = self.dawn_basal[int(t // 60) % 24] if self.dawn_basal else self.basal
        return b * scale

    def _insulin_effect(self, t, isf, horizon):
        """Future glucose change (mg/dL) from insulin already delivered, at t+k*5 min."""
        ks = np.arange(0, horizon + 1, 5)
        if not self.net_doses:
            return np.zeros(len(ks))
        recent = [(dt, u) for dt, u in self.net_doses if t - dt < TD + DELAY]
        self.net_doses = recent
        dts = np.array([d for d, _ in recent]); us = np.array([u for _, u in recent])
        now_iob = iob_fraction(t - dts)
        eff = np.zeros(len(ks))
        for i, k in enumerate(ks):
            eff[i] = -isf * np.sum(us * (now_iob - iob_fraction(t + k - dts)))
        return eff

    def _carb_effect(self, t, isf, cr, horizon):
        ks = np.arange(0, horizon + 1, 5)
        eff = np.zeros(len(ks))
        self.carbs = [(ct, g) for ct, g in self.carbs if t - ct < self.carb_abs + 30]
        for ct, g in self.carbs:
            def absorbed(x):
                return np.clip((x - ct - 10) / self.carb_abs, 0, 1) * g
            eff += (absorbed(t + ks) - absorbed(t)) * isf / cr
        return eff

    def iob(self, t):
        if not self.net_doses:
            return 0.0
        dts = np.array([d for d, _ in self.net_doses]); us = np.array([u for _, u in self.net_doses])
        return float(np.sum(us * iob_fraction(t - dts)))

    def step(self, t, bg_hist, scale=1.0, target=None):
        """bg_hist: list of (t, bg). Returns (temp_basal_uph, auto_bolus_units).
        target: optional override target (like a Loop override's target range)."""
        saved = self.target
        if target is not None:
            self.target = target
        try:
            return self._step(t, bg_hist, scale)
        finally:
            self.target = saved

    def _step(self, t, bg_hist, scale=1.0):
        isf, cr = self.isf / scale, self.cr / scale
        bg = bg_hist[-1][1]
        horizon = 360
        ins = self._insulin_effect(t, isf, horizon)
        carb = self._carb_effect(t, isf, cr, horizon)
        # Retrospective correction: compare what happened over the last 30 min with what was predicted.
        rc = np.zeros(len(ins))
        past = self.pred_hist.get(t - 30)
        if past is not None:
            discrepancy = bg - past
            vel = discrepancy / 30.0
            ks = np.arange(0, horizon + 1, 5)
            # Loop-style: carry the discrepancy velocity forward, fading over 60 min.
            rc = np.array([vel * (min(k, 60) - min(k, 60) ** 2 / 120) for k in ks])
        pred = bg + ins + carb + rc
        self.pred_hist[t] = bg + ins[6] + carb[6]
        for k in list(self.pred_hist):
            if k < t - 60:
                del self.pred_hist[k]

        sched = self.scheduled_basal(t, scale)
        min_pred = pred[:37].min()   # next 3 h
        eventual = pred[-1]
        if min_pred < self.suspend:
            return 0.0, 0.0
        if eventual < self.target:
            correction = (eventual - self.target) / isf
            rate = max(0.0, sched + correction / 0.5)
            return min(rate, self.max_basal), 0.0
        correction = (min(eventual, max(min_pred, self.target) + (eventual - min_pred)) - self.target) / isf
        if correction <= 0.05:
            return sched, 0.0
        # Don't exceed a max IOB of ~3x hourly basal + max bolus.
        headroom = max(0.0, (self.max_bolus + 3 * self.basal) - self.iob(t))
        bolus = min(correction * self.autobolus_fraction, self.max_bolus, headroom)
        bolus = math.floor(bolus / 0.05) * 0.05
        return sched, bolus

    def record_delivery(self, t, units_net):
        if abs(units_net) > 1e-6:
            self.net_doses.append((t, units_net))
