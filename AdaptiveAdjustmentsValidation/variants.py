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
