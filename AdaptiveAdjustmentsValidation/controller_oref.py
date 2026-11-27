"""A simplified OpenAPS/oref1-style controller (Trio-like), written from the published algorithm
description — not Trio's code. Features: SMB (super micro boluses), UAM (unannounced meal)
prediction from deviations, logarithmic Dynamic ISF from total daily dose, max IOB, low guard.
Same interface as controller.LoopController so the simulator can swap it in.
"""
import math
import numpy as np
from controller import iob_fraction, DELAY, TD


def activity_fraction(t):
    """Fraction of a dose absorbed per minute at t minutes (numerical derivative of IOB)."""
    t = np.asarray(t, dtype=float)
    return (iob_fraction(t - 0.5) - iob_fraction(t + 0.5))


class OrefController:
    def __init__(self, basal_uph, isf, cr, target=105, suspend=70, max_basal_mult=4.0,
                 smb=True, uam=True, dynamic_isf=True, adjustment_factor=0.8, smb_basal_minutes=30,
                 smb_fraction=0.5, autosens_range=(0.7, 1.2), max_bolus=10.0, avg_meal_g=60):
        self.basal, self.isf, self.cr = basal_uph, isf, cr
        self.target, self.suspend = target, suspend
        self.max_basal = basal_uph * max_basal_mult
        self.smb, self.uam, self.dynamic = smb, uam, dynamic_isf
        self.af = adjustment_factor
        self.smb_minutes = smb_basal_minutes
        self.smb_fraction = smb_fraction
        self.as_lo, self.as_hi = autosens_range
        self.max_bolus = max_bolus
        # Trio docs' starting point: average meal bolus + 3x max daily basal.
        self.max_iob = avg_meal_g / cr + 3 * basal_uph
        self.net_doses, self.carbs = [], []
        self.carb_abs = 180
        self.tdd_24, self.tdd_7d = None, None
        self.dawn_basal = None
        self.last_smb_t = -10 ** 9

    def scheduled_basal(self, t, scale):
        return self.basal * scale

    def update_tdd(self, tdd_24, tdd_7d):
        self.tdd_24, self.tdd_7d = tdd_24, tdd_7d

    def record_delivery(self, t, units_net):
        if abs(units_net) > 1e-6:
            self.net_doses.append((t, units_net))

    def _arrays(self, t):
        self.net_doses = [(d, u) for d, u in self.net_doses if t - d < TD + DELAY]
        if not self.net_doses:
            return np.zeros(0), np.zeros(0)
        return np.array([d for d, _ in self.net_doses]), np.array([u for _, u in self.net_doses])

    def iob(self, t):
        dts, us = self._arrays(t)
        return float(np.sum(us * iob_fraction(t - dts))) if len(dts) else 0.0

    def _isf(self, bg, scale):
        isf = self.isf / scale
        if not self.dynamic or not self.tdd_24:
            return isf
        tdd = 0.65 * self.tdd_24 + 0.35 * (self.tdd_7d or self.tdd_24)
        ins_factor = 120 - 75   # rapid-acting peak 75 min
        dyn = 1800 / (tdd * math.log(max(bg, 40) / ins_factor + 1)) / self.af
        ratio = min(max(isf / dyn, self.as_lo), self.as_hi)   # bounded like autosens min/max
        return isf / ratio

    def step(self, t, bg_hist, scale=1.0, target=None):
        tgt = target if target is not None else self.target
        bg = bg_hist[-1][1]
        isf = self._isf(bg, scale)
        cr = self.cr / scale
        sched = self.scheduled_basal(t, scale)
        dts, us = self._arrays(t)
        ks = np.arange(0, 241, 5)   # 4 h horizon

        # Insulin effect (IOB curve) and current BGI per 5 min.
        if len(dts):
            now_iob = iob_fraction(t - dts)
            ins = np.array([-isf * np.sum(us * (now_iob - iob_fraction(t + k - dts))) for k in ks])
            bgi = -isf * np.sum(us * activity_fraction(t - dts)) * 5
        else:
            ins = np.zeros(len(ks)); bgi = 0.0
        iob = float(np.sum(us * iob_fraction(t - dts))) if len(dts) else 0.0

        # Deviation: observed 5-min change minus insulin-expected change (averaged over 15 min).
        devs = []
        for j in range(1, 4):
            if len(bg_hist) > j:
                devs.append((bg_hist[-j][1] - bg_hist[-j - 1][1]) - bgi)
        dev = float(np.mean(devs)) if devs else 0.0

        # COB-based prediction from carb entries (linear absorption).
        self.carbs = [(ct, g) for ct, g in self.carbs if t - ct < self.carb_abs + 30]
        carb = np.zeros(len(ks)); cob = 0.0
        for ct, g in self.carbs:
            def absorbed(x): return np.clip((x - ct - 10) / self.carb_abs, 0, 1) * g
            carb += (absorbed(t + ks) - absorbed(t)) * isf / cr
            cob += g - float(absorbed(t))

        iob_pred = bg + ins
        cob_pred = bg + ins + carb
        # UAM: positive deviation assumed to continue, decaying linearly to zero over ~3 h.
        if self.uam and dev > 0:
            decay = np.clip(1 - ks / 180.0, 0, 1)
            uam_add = np.cumsum(np.concatenate([[0], dev * decay[1:]]))
            uam_pred = bg + ins + uam_add
        else:
            uam_pred = iob_pred
        # Zero-temp prediction: stopping basal now removes insulin, so glucose ends up *higher*
        # than the IOB prediction by the action of the basal not delivered.
        taus = np.arange(0, 241, 5)
        removed = np.array([np.sum((1 - iob_fraction(k - taus[taus < k])) * sched * 5 / 60) for k in ks])
        zt_pred = iob_pred + isf * removed

        # Combine predictions the way oref1 does (simplified): with carbs on board, blend the COB
        # and UAM minimums by the fraction of carbs left; with UAM and no carbs, trust the higher of
        # the IOB and UAM minimums; never go below the IOB-only minimum.
        min_iob = iob_pred[6:].min(); min_uam = uam_pred[6:].min(); min_zt = zt_pred[6:].min()
        if cob > 1:
            total_g = sum(g for _, g in self.carbs) or 1.0
            frac_left = min(1.0, cob / total_g)
            blended = frac_left * cob_pred[6:].min() + (1 - frac_left) * min_uam
            min_pred = max(min_iob, min_zt, blended)
            eventual = frac_left * cob_pred[-1] + (1 - frac_left) * uam_pred[-1]
        elif self.uam:
            min_pred = max(min_iob, min_uam)
            eventual = uam_pred[-1]
        else:
            min_pred = min_iob
            eventual = iob_pred[-1]
        min_guard = min(iob_pred.min(), zt_pred.min())

        if min_guard < self.suspend or bg < self.suspend:
            return 0.0, 0.0
        insulin_req = (min(min_pred, eventual) - tgt) / isf
        if insulin_req <= 0:
            rate = max(0.0, sched + 2 * insulin_req)   # oref: deliver the shortfall over ~30 min
            return min(rate, self.max_basal), 0.0
        insulin_req = min(insulin_req, max(0.0, self.max_iob - iob))
        smb = 0.0
        if self.smb and t - self.last_smb_t >= 5:
            cap = sched * self.smb_minutes / 60
            smb = min(insulin_req * self.smb_fraction, cap, self.max_bolus)
            smb = math.floor(smb / 0.05) * 0.05
            if smb > 0:
                self.last_smb_t = t
        rate = min(self.max_basal, sched + 2 * max(0.0, insulin_req - smb))
        return rate, smb
