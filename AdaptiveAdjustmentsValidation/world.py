"""Synthetic 'life' for a virtual patient: meals (with messy carb entries), exercise,
sleep, site changes and failures, illness, hidden stress, alcohol, dawn phenomenon.

Everything is expressed in minutes since sim start. The hidden truth is two functions:
  needs(t)      -> multiplier on insulin needs (1.2 = needs 20% more insulin)
  absorption(t) -> fraction of delivered insulin that actually gets absorbed
The adaptive layer never sees these, only the observable signals.
"""
import math
import numpy as np

DAY = 1440


class World:
    def __init__(self, seed, days, dawn=True):
        r = np.random.default_rng(seed)
        self.days = days
        self.rng = r
        n = days * DAY
        needs = np.ones(n)
        absorb = np.ones(n)
        self.meals = []          # (t, true_g, announced_g or None, bolused: bool)
        self.workouts = []       # (start, end)
        self.nights = []         # (wake_t, asleep_minutes)
        self.site_changes = []   # t
        self.site_failures = []  # (start, planned_end)
        self.alcohol = []        # (t, logged)
        self.illness = []        # (start, end, logged)
        self.stress_days = []    # day index (hidden; only HRV shows it)

        # Day-to-day unexplained variation.
        daily = np.exp(r.normal(0, 0.07, days))
        for d in range(days):
            needs[d * DAY:(d + 1) * DAY] *= daily[d]

        # Dawn phenomenon: 4–8am need more insulin.
        if dawn:
            for d in range(days):
                needs[d * DAY + 4 * 60: d * DAY + 8 * 60] *= 1.25

        # Sleep: wake ~6:30–7:30, ~25% short nights.
        for d in range(1, days):
            wake = d * DAY + int(r.uniform(390, 450))
            short = r.random() < 0.25
            asleep = int(r.uniform(270, 340) if short else r.uniform(400, 480))
            self.nights.append((wake, asleep))
            if short:
                needs[wake: wake + 8 * 60] *= 1.2

        # Meals: breakfast, lunch, dinner + occasional snack. Carb entries are messy.
        for d in range(days):
            weekend = (d % 7) in (5, 6)
            plan = [(8.0 if not weekend else 9.5, 45), (12.5, 60), (18.5, 75)]
            for hour, g in plan:
                t = d * DAY + int(hour * 60 + r.normal(0, 25))
                true_g = max(10, r.normal(g, g * 0.3))
                if r.random() < 0.15:          # forgot to enter / bolus entirely
                    self.meals.append((t, true_g, None, False))
                else:
                    announced = true_g * math.exp(r.normal(-0.1, 0.35))   # tends to undercount
                    self.meals.append((t, true_g, round(announced / 5) * 5, True))
            if r.random() < 0.4:                  # unannounced snack
                t = d * DAY + int(r.uniform(14.5, 16.5) * 60)
                self.meals.append((t, r.uniform(15, 30), None, False))
        self.meals.sort()

        # Exercise ~3/week, morning or evening, 40–75 min.
        for d in range(days):
            if r.random() < 3 / 7:
                start = d * DAY + int((7 if r.random() < 0.4 else 17.25) * 60 + r.normal(0, 20))
                dur = int(r.uniform(40, 75))
                self.workouts.append((start, start + dur))
                needs[start: start + dur + 120] *= 0.55          # during and 2 h after
                needs[start + dur + 120: start + dur + 720] *= 0.8   # delayed, overnight

        # Site changes every ~3 days; day 3 absorbs less; occasional failures.
        t = int(r.uniform(9, 11) * 60)
        while t < n:
            self.site_changes.append(t)
            nxt = t + 3 * DAY + int(r.normal(0, 60))
            absorb[t + 2 * DAY: nxt] *= 0.88
            if r.random() < 0.12:
                fail = t + int(r.uniform(0.3, 2.5) * DAY)
                self.site_failures.append((fail, nxt))
            t = nxt

        # Illness: one 2-day episode per ~month.
        for d in range(5, days, 30):
            start = (d + int(r.integers(0, 20))) * DAY + 8 * 60
            end = start + 2 * DAY
            self.illness.append((start, end, r.random() < 0.6))
            needs[start:end] *= 1.35

        # Hidden stress days (~10%): need more insulin, HRV dips, never logged.
        for d in range(days):
            if r.random() < 0.10:
                self.stress_days.append(d)
                needs[d * DAY:(d + 1) * DAY] *= 1.15

        # Alcohol ~1/week at 20:00: delayed sensitivity.
        for d in range(days):
            if r.random() < 1 / 7:
                t = d * DAY + 20 * 60
                self.alcohol.append((t, r.random() < 0.7))
                needs[t + 120: t + 14 * 60] *= 0.8

        self.needs = needs
        self.base_absorb = absorb

        # Physiology readings (daily morning values).
        self.rhr, self.hrv, self.temp = [], [], []
        ill_days = set()
        for s, e, _ in self.illness:
            for d in range(s // DAY, e // DAY + 1):
                ill_days.add(d)
        for d in range(days):
            t = d * DAY + 7 * 60
            sick = d in ill_days
            stressed = d in self.stress_days
            self.rhr.append((t, 60 + r.normal(0, 2) + (9 if sick else 0) + (3 if stressed else 0)))
            self.hrv.append((t, max(10, 50 + r.normal(0, 6)) * (0.65 if (sick or stressed) else 1.0)))
            self.temp.append((t, 34.5 + r.normal(0, 0.15) + (0.8 if sick else 0)))

    def logs(self):
        out = [(t, "alcohol") for t, logged in self.alcohol if logged]
        out += [(s, "illness") for s, _, logged in self.illness if logged]
        return sorted(out)
