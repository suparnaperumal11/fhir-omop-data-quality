"""Inspect Synthea FHIR bundles before writing any parser.

Walks each bundle recursively and reports what is actually present, rather than
assuming known paths. Read-only: writes nothing, transforms nothing.

Usage:  python src/ingest/explore_fhir.py [fhir_dir]
"""

import glob
import json
import os
import sys
from collections import Counter, defaultdict

FHIR_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join("output", "fhir")

# Bundles Synthea emits that are not per-patient records.
NON_PATIENT_PREFIXES = ("hospitalInformation", "practitionerInformation")

DATE_HINTS = (
    "date", "period", "onset", "abatement", "effective", "issued",
    "recorded", "authored", "start", "end", "deceased", "birth",
)


def norm(path):
    """Collapse array indices so Foo[0].bar and Foo[3].bar report as one path."""
    out = []
    for part in path:
        out.append("[]" if isinstance(part, int) else part)
    joined = ""
    for part in out:
        if part == "[]":
            joined += "[]"
        else:
            joined = f"{joined}.{part}" if joined else part
    return joined


def walk(node, path, visit):
    visit(node, path)
    if isinstance(node, dict):
        for k, v in node.items():
            walk(v, path + [k], visit)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path + [i], visit)


def main():
    files = sorted(glob.glob(os.path.join(FHIR_DIR, "*.json")))
    if not files:
        sys.exit(f"No JSON found in {FHIR_DIR}")

    patient_files, other_files = [], []
    for f in files:
        base = os.path.basename(f)
        (other_files if base.startswith(NON_PATIENT_PREFIXES) else patient_files).append(f)

    bundle_keys = Counter()
    entry_keys = Counter()
    fullurl_fmt = Counter()
    res_counts = Counter()
    res_counts_by_file = defaultdict(Counter)
    other_res_counts = Counter()

    # resourceType -> top-level field -> number of resources having it
    field_presence = defaultdict(Counter)
    res_totals = Counter()

    # resourceType -> path-of-CodeableConcept -> Counter(system)
    cc_systems = defaultdict(lambda: defaultdict(Counter))
    cc_len = defaultdict(Counter)          # resourceType -> len(coding) -> n
    ref_fmt = defaultdict(Counter)         # resourceType -> format label -> n
    ref_paths = defaultdict(Counter)       # resourceType -> path -> n
    ref_examples = {}
    date_paths = defaultdict(Counter)      # resourceType -> date-ish path -> n
    obs_value = Counter()                  # value[x] variant -> n
    obs_value_by_cat = defaultdict(Counter)
    obs_cats = Counter()

    def scan_resource(res, rtype):
        def visit(node, path):
            if not isinstance(node, dict):
                return
            p = norm(path)
            if isinstance(node.get("coding"), list):
                cc_len[rtype][len(node["coding"])] += 1
                for c in node["coding"]:
                    if isinstance(c, dict):
                        cc_systems[rtype][p or "<root>"][c.get("system", "<none>")] += 1
            ref = node.get("reference")
            if isinstance(ref, str):
                if ref.startswith("urn:uuid:"):
                    label = "urn:uuid:<id>"
                elif "/" in ref and not ref.startswith("http"):
                    label = f"{ref.split('/')[0]}/<id>"
                elif ref.startswith("http"):
                    label = "absolute URL"
                else:
                    label = "other"
                ref_fmt[rtype][label] += 1
                ref_paths[rtype][p] += 1
                ref_examples.setdefault(label, ref)

        walk(res, [], visit)

        for k, v in res.items():
            lk = k.lower()
            if any(h in lk for h in DATE_HINTS):
                if isinstance(v, str):
                    date_paths[rtype][k] += 1
                elif isinstance(v, dict):
                    for sub in v:
                        date_paths[rtype][f"{k}.{sub}"] += 1

    for f in patient_files:
        with open(f, encoding="utf-8") as fh:
            bundle = json.load(fh)
        base = os.path.basename(f)
        bundle_keys.update(bundle.keys())
        for entry in bundle.get("entry", []):
            entry_keys.update(entry.keys())
            fu = entry.get("fullUrl", "")
            fullurl_fmt["urn:uuid:<id>" if fu.startswith("urn:uuid:") else (fu[:24] or "<none>")] += 1
            res = entry.get("resource", {})
            rtype = res.get("resourceType", "<none>")
            res_counts[rtype] += 1
            res_counts_by_file[base][rtype] += 1
            res_totals[rtype] += 1
            for k in res:
                field_presence[rtype][k] += 1
            scan_resource(res, rtype)

            if rtype == "Observation":
                variants = [k for k in res if k.startswith("value")]
                v = variants[0] if variants else "<no value[x]>"
                obs_value[v] += 1
                cats = []
                for c in res.get("category", []):
                    for cd in c.get("coding", []):
                        cats.append(cd.get("code", "?"))
                cat = cats[0] if cats else "<none>"
                obs_cats[cat] += 1
                obs_value_by_cat[cat][v] += 1

    for f in other_files:
        with open(f, encoding="utf-8") as fh:
            bundle = json.load(fh)
        for entry in bundle.get("entry", []):
            other_res_counts[entry.get("resource", {}).get("resourceType", "<none>")] += 1

    w = sys.stdout.write
    def hdr(t):
        w("\n" + "=" * 72 + "\n" + t + "\n" + "=" * 72 + "\n")

    hdr("1. BUNDLE SHAPE")
    w(f"Patient bundles      : {len(patient_files)}\n")
    w(f"Non-patient bundles  : {len(other_files)} "
      f"({', '.join(os.path.basename(x)[:28] for x in other_files)})\n")
    w(f"Bundle top-level keys: {dict(bundle_keys)}\n")
    w(f"Entry keys           : {dict(entry_keys)}\n")
    w(f"fullUrl format       : {dict(fullurl_fmt)}\n")
    w(f"\nTotal resources across patient bundles: {sum(res_counts.values())}\n\n")
    w(f"{'resourceType':<28}{'count':>8}{'per-bundle min..max':>22}\n")
    for rt, n in res_counts.most_common():
        per = [res_counts_by_file[b].get(rt, 0) for b in res_counts_by_file]
        w(f"{rt:<28}{n:>8}{f'{min(per)}..{max(per)}':>22}\n")
    w(f"\nNon-patient bundle contents: {dict(other_res_counts)}\n")

    hdr("2. WHERE CLINICAL CODES LIVE  (system per CodeableConcept path)")
    for rt in [r for r, _ in res_counts.most_common()]:
        if rt not in cc_systems:
            continue
        w(f"\n--- {rt} ---\n")
        w(f"    coding[] length distribution: {dict(sorted(cc_len[rt].items()))}\n")
        for path, systems in sorted(cc_systems[rt].items()):
            w(f"    {path}\n")
            for s, n in systems.most_common():
                w(f"        {n:>6}  {s}\n")

    hdr("3. HOW REFERENCES ARE WRITTEN")
    w("Examples seen: " + json.dumps(ref_examples, indent=2) + "\n\n")
    for rt in [r for r, _ in res_counts.most_common()]:
        if rt not in ref_fmt:
            continue
        w(f"{rt:<28} {dict(ref_fmt[rt])}\n")
        for p, n in ref_paths[rt].most_common(6):
            w(f"    {n:>6}  {p}\n")

    hdr("4. DATE FIELDS PRESENT PER RESOURCE TYPE")
    for rt in [r for r, _ in res_counts.most_common()]:
        if rt in date_paths:
            total = res_totals[rt]
            parts = [f"{p} ({n}/{total})" for p, n in date_paths[rt].most_common()]
            w(f"{rt:<28} {', '.join(parts)}\n")

    hdr("5. OBSERVATION value[x] VARIANTS")
    tot = sum(obs_value.values())
    for v, n in obs_value.most_common():
        w(f"{v:<28}{n:>8}  {100*n/tot:5.1f}%\n")
    w(f"{'TOTAL':<28}{tot:>8}\n")
    w("\nBy Observation.category:\n")
    for cat, n in obs_cats.most_common():
        w(f"  {cat} (n={n}): {dict(obs_value_by_cat[cat])}\n")

    hdr("6. OPTIONALITY  (field presence, resources with >=20 instances)")
    for rt, _ in res_counts.most_common():
        total = res_totals[rt]
        if total < 20:
            continue
        always = [k for k, n in field_presence[rt].items() if n == total]
        somet = sorted(((k, n) for k, n in field_presence[rt].items() if n < total),
                       key=lambda x: -x[1])
        w(f"\n--- {rt} (n={total}) ---\n")
        w(f"    ALWAYS   : {', '.join(sorted(always))}\n")
        if somet:
            w("    SOMETIMES:\n")
            for k, n in somet:
                w(f"        {k:<28}{n:>6}/{total}  {100*n/total:5.1f}%\n")
        else:
            w("    SOMETIMES: (none - all fields always present)\n")


if __name__ == "__main__":
    main()
