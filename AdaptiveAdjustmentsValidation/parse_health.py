"""Line-based parse of Apple Health export.xml (tolerates the malformed bytes Apple exports contain)."""
import sys, zipfile, csv, collections, re, io
zpath, out = sys.argv[1], sys.argv[2]
WANT = {
 "HKQuantityTypeIdentifierBloodGlucose": "glucose",
 "HKQuantityTypeIdentifierInsulinDelivery": "insulin",
 "HKQuantityTypeIdentifierDietaryCarbohydrates": "carbs",
 "HKCategoryTypeIdentifierSleepAnalysis": "sleep",
 "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv",
 "HKQuantityTypeIdentifierRestingHeartRate": "rhr",
 "HKQuantityTypeIdentifierAppleSleepingWristTemperature": "temp",
}
ATTR = re.compile(r'(\w+)="([^"]*)"')
writers, files = {}, {}
counts, sources = collections.Counter(), collections.Counter()
def w(name):
    if name not in writers:
        files[name] = open(f"{out}/{name}.csv", "w", newline=""); writers[name] = csv.writer(files[name])
    return writers[name]
cur = None
with zipfile.ZipFile(zpath) as z, z.open("apple_health_export/export.xml") as fb:
    for line in io.TextIOWrapper(fb, encoding="utf-8", errors="replace"):
        s = line.lstrip()
        if s.startswith("<Record "):
            a = dict(ATTR.findall(s))
            name = WANT.get(a.get("type"))
            if name:
                cur = (name, a, {})
                if s.rstrip().endswith("/>"):
                    pass
                else:
                    continue
            else:
                cur = None; continue
        elif cur and s.startswith("<MetadataEntry"):
            m = dict(ATTR.findall(s)); cur[2][m.get("key")] = m.get("value"); continue
        elif cur and s.startswith("</Record>"):
            pass
        elif s.startswith("<Workout "):
            a = dict(ATTR.findall(s))
            w("workouts").writerow([a.get("startDate"), a.get("endDate"), a.get("workoutActivityType"), a.get("duration"), a.get("sourceName")])
            counts["workouts"] += 1; continue
        else:
            continue
        if cur:
            name, a, meta = cur
            w(name).writerow([a.get("startDate"), a.get("endDate"), a.get("value"), a.get("unit"), a.get("sourceName"),
                              meta.get("HKInsulinDeliveryReason", ""), "|".join(f"{k}={v}" for k, v in meta.items() if "Automatic" in k or "Manual" in k or "Programmed" in k or "Scheduled" in k)])
            counts[name] += 1; sources[(name, a.get("sourceName"))] += 1
            cur = None
for f in files.values(): f.close()
print(dict(counts))
for k, v in sorted(sources.items(), key=lambda x: -x[1])[:25]: print(k, v)
