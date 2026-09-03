import glob, os, re, statistics, sys
PAT = re.compile(r"eval time =\s*([0-9.]+) ms /\s*(\d+) tokens \(\s*[0-9.]+ ms per token,\s*([0-9.]+) tokens per second\)")
root = sys.argv[1]
print("model\tarm\tn_requests\tmedian_decode_tok_s\tmin\tmax")
rows = {}
for model_dir in sorted(glob.glob(os.path.join(root, "*", "*", "*"))):
    model = os.path.basename(os.path.dirname(model_dir))
    arm = os.path.basename(model_dir)
    log = os.path.join(model_dir, "server.log")
    if not os.path.exists(log):
        continue
    rates = []
    for line in open(log, encoding="utf-8", errors="replace"):
        m = PAT.search(line)
        if m and int(m.group(2)) >= 128:      # the 256-token generation, not the prompt
            rates.append(float(m.group(3)))
    if not rates:
        continue
    rows.setdefault(model, {})[arm] = rates
    print("%s\t%s\t%d\t%.2f\t%.2f\t%.2f" % (
        model, arm, len(rates), statistics.median(rates), min(rates), max(rates)))
print()
print("model\tcontrol_median\tsubject_median\tdelta_pct\tcontrol_drift_pct")
for model, arms in sorted(rows.items()):
    o = arms.get("control-open"); s = arms.get("subject"); c = arms.get("control-close")
    if not (o and s and c):
        continue
    om, sm, cm = statistics.median(o), statistics.median(s), statistics.median(c)
    control = statistics.median(o + c)
    print("%s\t%.2f\t%.2f\t%+.2f%%\t%+.2f%%" % (
        model, control, sm, 100.0 * (sm - control) / control, 100.0 * (cm - om) / om))
