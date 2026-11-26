CAL = {"isf_mult": {"adult#001": 3.0, "adult#004": 1.5, "adult#006": 1.5}}
def v(**kw):
    d = dict(CAL); d.update(kw); return d
VARIANTS = {
    "base": v(),
    "ideal": v(ideal=True, arms=["loop"]),
}
REDUCE_PRIORS = {"exerciseEarly": 0.8, "exerciseLate": 0.9, "alcohol": 0.9}
VARIANTS.update({
    "v1": v(arms=["adaptive"], activity=True, meal_after=300, min_episodes=4, rules={"use_weekend": False}),
    "v2": v(arms=["adaptive"], activity=True, meal_after=300, min_episodes=4, rules={"use_weekend": False}, priors=REDUCE_PRIORS),
    "v3": v(arms=["adaptive"], activity=True, meal_after=300, min_episodes=4, rules={"use_weekend": False}, priors=REDUCE_PRIORS, outcome=True),
})
V2 = dict(activity=True, meal_after=300, min_episodes=4, rules={"use_weekend": False}, priors=REDUCE_PRIORS)
NEW = {"ride_prep", "post_target", "tod", "stack_guard"}
WIDE = {"min_scale": 0.5, "max_scale": 1.5, "abs_min": 0.5, "abs_max": 1.5}
VARIANTS.update({
    "alan": v(alan=True, arms=["loop"]),
    "alan_v2": v(alan=True, arms=["adaptive"], **V2),
    "alan_v4": v(alan=True, arms=["adaptive"], features=NEW, **V2),
    "alan_v4w": v(alan=True, arms=["adaptive"], features=NEW, cfg=WIDE, **V2),
    "smoke": v(alan=True, arms=["adaptive"], features=NEW, cfg=WIDE, **V2),
})
VARIANTS.update({
    "alan_v5": v(alan=True, arms=["adaptive"], features={"post_target", "tod"}, **V2),
    "alan_v5w": v(alan=True, arms=["adaptive"], features={"post_target", "tod"}, cfg=WIDE, **V2),
})
