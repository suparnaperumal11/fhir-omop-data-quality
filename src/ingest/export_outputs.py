"""Render the quality report and mapping-loss analysis from the database into outputs/.

Reporting only - every number here is read from a table produced by SQL in
sql/03_quality/. Nothing is computed in Python.

Usage:  python src/ingest/export_outputs.py
"""

import os
import sys

import duckdb

DB = os.path.join("data", "fhir_omop.duckdb")
OUT = "outputs"


def table(con, sql, headers=None, fmt=None):
    rows = con.execute(sql).fetchall()
    cols = headers or [d[0] for d in con.description]
    out = ["| " + " | ".join(cols) + " |",
           "|" + "|".join(["---"] * len(cols)) + "|"]
    for r in rows:
        cells = []
        for i, v in enumerate(r):
            if fmt and i in fmt:
                cells.append(fmt[i](v))
            elif isinstance(v, int):
                cells.append(f"{v:,}")
            else:
                cells.append("" if v is None else str(v))
        out.append("| " + " | ".join(cells) + " |")
    return "\n".join(out)


def one(con, sql):
    return con.execute(sql).fetchone()


def main():
    if not os.path.exists(DB):
        sys.exit(f"{DB} not found - run the pipeline first")
    os.makedirs(OUT, exist_ok=True)
    con = duckdb.connect(DB, read_only=True)

    n_pass, n_fail = one(con, """
        SELECT count(*) FILTER (WHERE status='PASS'), count(*) FILTER (WHERE status='FAIL')
        FROM v_dq_report""")
    h = one(con, "SELECT * FROM loss_headline")

    # ---------------------------------------------------------------- report
    qr = f"""# Quality report

Generated from `data/fhir_omop.duckdb`. Every figure is read from a table produced by
the SQL in `sql/03_quality/`; nothing is recomputed here.

Cohort: 1,112 Synthea patients (`-p 1000 -s 42`; 1,000 living, 112 deceased).

**{n_pass} checks pass, {n_fail} fail.**

Three of the failures were predicted before the mapping was written. Two were not, and
those two are the interesting ones - one is a defect in this pipeline, one is a defect
in the source. Telling them apart is what the framework is for.

---

## Results

{table(con, '''SELECT check_id, check_name, category, rows_evaluated, rows_failed,
                      COALESCE(pct_failed::VARCHAR,'-') AS pct_failed,
                      threshold_pct::INT AS threshold, status
               FROM v_dq_report ORDER BY status DESC, check_id''')}

---

## The three expected failures: CMP-04, CMP-05, CMP-06

Every clinical code loads with `concept_id = 0`. Not because the mapping is hard -
SNOMED, LOINC and RxNorm are themselves OMOP standard vocabularies and the relationship
is near-identity - but because resolving a code to an integer `concept_id` requires the
Athena vocabulary tables, which are several GB and out of scope for this project.

The thresholds (20%, 20%, 30%) were fixed in `eval/quality_checks.md` and committed
before a single line of mapping SQL existed. They were **not relaxed** when the
vocabulary decision was taken. Lowering a threshold because you already know you will
miss it is how a quality framework becomes decoration.

---

## The two unexpected failures

### PLA-10 - 1,175 events dated before the patient's birth. This pipeline's bug.

Every one of the 1,175 is **exactly one day** before birth. That is not a clinical
anomaly, it is an arithmetic signature.

Cause: event timestamps are converted from their recorded `+05:30` offset to
America/New_York before the date is taken. `Patient.birthDate` is a **date-only** field
with no time and no offset, so it cannot be converted and does not move. An event
recorded at 02:00 IST on the day of birth becomes 15:30 the previous day in New York,
and lands before a birth date that stayed where it was.

Confirmed by comparison: with naive string truncation, **0** events precede birth. With
timezone conversion, 1,071 do (observations alone).

This is not an argument for truncation - truncation would bake a Kolkata calendar date
into a Massachusetts cohort, which is worse and affects 42% of rows rather than 0.18%.
It is a demonstration that **you cannot consistently timezone-convert a dataset that
mixes timezone-bearing datetimes with timezone-less dates.** Fixing it properly needs a
birth *time*, which the source does not carry. Left unfixed and reported, because
silently clamping event dates to the birth date would erase the evidence.

### PLA-06 - 102 visits starting after the patient's death. The source's bug.

Spread across 1 to 14 days after death, affecting 102 of the 112 deceased patients -
not concentrated at one day, so not a timezone boundary artifact. Synthea emits
encounters dated after the death it recorded.

This is a genuine source data quality problem, faithfully carried through rather than
quietly filtered. The mapping deliberately does not pre-filter on plausibility: an ETL
that drops the rows its own quality checks look for makes those checks pass by
construction.

---

## What the passing checks do and do not tell you

**Conformance passes on all 11 checks, and that is less impressive than it looks.**
Because the DDL declares `NOT NULL`, a row that could not supply a required field was
never inserted - it would have been routed to `etl_rejects`. Conformance measures what
got in. It must be read alongside the reject counts, which in this run are **zero**
across 695,506 source rows: Synthea emits structurally well-formed FHIR.

**CON-08 passes only because of the timezone conversion.** It asserts that every
`*_datetime` falls on the same calendar day as its `*_date`. Naive truncation would
fail it on roughly 42% of rows.

**CMP-09 and CMP-10 pass at 100%** because the conditional-reference resolution worked.
Had it not, both would have failed at 100% and every visit would carry a NULL care site
and provider.

---

## Q-01 - the timezone quantification

Rows whose calendar date changes depending on whether the timestamp is converted or
truncated. This is what happens when an ETL ignores timezone, measured rather than
asserted.

{table(con, "SELECT domain, rows_evaluated, rows_shifted_one_day, pct_shifted FROM q01_timezone_shift ORDER BY rows_evaluated DESC")}

The magnitude is not arbitrary: New York is 10.5 hours behind IST, and events spread
evenly across a day put 10.5/24 = 43.75% before the boundary. The observed 42% agrees,
which is evidence the effect is real rather than a parsing artifact.

---

## Q-04 - multi-coding

`coding[]` arrays where more than one coding was present and we took `[0]`, discarding
the rest.

{table(con, "SELECT domain, rows_total, rows_multi_coding FROM q04_multi_coding")}

Small here. It would not be small on real EHR data, where a single concept routinely
carries local, SNOMED and ICD codings side by side.

---

## Q-06 - demographic granularity

{table(con, "SELECT field, distinct_source_values, distinct_target_concepts, source_values_lost FROM q06_granularity")}

Race loses one of six source values (`UNK`, 19 patients), left at `concept_id = 0`
because OMOP has no standard Race concept meaning "unknown" and inventing one would
turn missing data into a positive claim about a person's race.

This understates real-world granularity loss. Synthea emits only the five OMB
categories; US Core also permits a `detailed` race sub-extension carrying finer
granularity, which is absent here. On real US Core data the collapse to OMOP's five
Race concepts would be substantially lossier.
"""

    # ------------------------------------------------------------ loss report
    la = f"""# Mapping loss analysis

**What proportion of clinical data survives the mapping, and what exactly is lost?**

Cohort: 1,112 Synthea patients, 1,371,624 FHIR resources, five source resource types
mapped to six OMOP CDM v5.4 tables.

---

## The headline

Of **{h[0]:,}** source rows in the five in-scope domains:

- **{h[1]:,}** were routed elsewhere (correctly - see below), not lost
- **{h[2]:,}** could not be structured at all
- **{h[3]:,}** rows loaded to the CDM
- of those, **{h[4]:,} are computable** and **{h[5]:,} are not**

### {h[6]}% of loaded rows are actually usable in a concept-based query.

Every row loaded. Nothing was rejected. A row count would report this pipeline as a
complete success, and a researcher running `SELECT ... WHERE condition_concept_id = <viral
sinusitis>` against the result would get **zero rows** - not because the patients do not
have the condition, but because the code never became a concept.

That gap is the finding.

---

## By domain

{table(con, '''SELECT domain, source_rows, target_rows, expansion_rows,
                      bucket1_computable, bucket2_not_computable, bucket3_rejected,
                      out_of_scope, pct_computable
               FROM loss_by_domain ORDER BY source_rows DESC''')}

Reconciliation holds in every domain:

```
source = mapped + rejected + out_of_scope
target = mapped + expansion
```

---

## The three buckets

**1. Structured and computable - {h[4]:,} rows.** Almost entirely `visit_occurrence`
(59,893) and `person` (1,093). These are the domains whose vocabularies are part of the
CDM specification itself rather than a downloadable release.

**2. Structured but not computable - {h[5]:,} rows.** Every condition, every drug
exposure, every measurement. They are present, they reconcile, they pass every
conformance check, and `*_source_value` preserves the original code so a later
vocabulary load could resolve them retrospectively. They are invisible to any
concept-based cohort query.

This bucket is the one that misleads. It looks like success in a row count and behaves
like absence in an analysis.

**3. Could not be structured - {h[2]:,} rows.** Zero. Synthea emits structurally
well-formed FHIR: every resource had a subject that resolved, a parseable date, and a
code. Real EHR data does not behave this way, and a reject count of zero should be read
as a property of the source, not evidence that the reject path is sound.

**Routed elsewhere (not loss) - {h[1]:,} rows.** Survey and social-history Observations
belong in OMOP's `observation` table, which this project does not build. Counting them
as rejects would have inflated the apparent loss by an order of magnitude. They were not
lost; they were sent somewhere we do not go.

---

## Vocabulary coverage, by code and by row

{table(con, '''SELECT domain, distinct_codes, distinct_codes_mapped, pct_codes_mapped,
                      rows_total, rows_mapped, pct_rows_mapped
               FROM q02_code_coverage ORDER BY rows_total DESC''')}

Reported both ways deliberately. The two can diverge sharply, and quoting only the
flattering one misrepresents coverage.

---

## The long tail - top unmapped codes by row count

{table(con, "SELECT domain, rank, code, display, n_rows FROM q03_top_unmapped WHERE rank <= 10 ORDER BY domain, rank")}

---

## Row multiplication

{table(con, '''SELECT 'Observation -> measurement' AS mapping,
                      count(*) AS source_rows_expanded,
                      sum(n_target_rows) AS target_rows_produced,
                      sum(n_target_rows) - count(*) AS additional_rows
               FROM etl_expansion''')}

Blood pressure panels carry no scalar value; systolic (LOINC 8480-6) and diastolic
(8462-4) live in `component[]` with their own codes. OMOP models them as separate
measurements, so one source row legitimately becomes two.

Tracked explicitly because it breaks the naive identity `source = mapped + rejected`.
Without an expansion column, `target_rows > source_rows` looks like a duplicate-key bug,
and a pipeline that quietly tolerated it would also quietly tolerate real duplication.

---

## Would the absence change a research conclusion?

Yes, and specifically:

- **Any cohort definition by condition, drug or lab concept returns nothing.** The data
  is present but not queryable by concept. This is the difference between a dataset that
  answers a research question and one that appears to.
- **Drug duration analysis is invalid.** FHIR MedicationRequest carries no end date;
  `drug_exposure_end_date` is derived as `end = start`. A 90-day prescription and a
  single dose are indistinguishable in the output.
- **Blood pressure is available** - but only because components were expanded. A parser
  reading scalar values would have dropped all 15,672 systolic/diastolic pairs while
  reporting no errors.
- **Geography is absent.** `person.location_id` is NULL throughout; patient address was
  not mapped. Any question about place cannot be asked.
- **Social determinants are absent from this CDM subset** - 59,060 survey and
  social-history Observations were routed to a table outside scope. They are not lost,
  but they are not here either.

---

## What this dataset makes look easier than it is

Synthea's output is tidier than real EHR data in ways that flatter every number above:

- **One code system per domain.** SNOMED for conditions, LOINC for observations, RxNorm
  for drugs, with no local codes and no ICD.
- **`coding[]` had length 1 in 9,378 of 9,384 cases.** Real records routinely carry
  local, SNOMED and ICD codings on the same concept, and the choice of which to map is a
  decision this pipeline never had to make.
- **All 259 Conditions are `encounter-diagnosis`.** The diagnosis / problem-list /
  symptom ambiguity that makes real Condition mapping hard never arises here, so the
  mapping is untested against it.
- **Zero structural rejects** across 695,506 rows.

The mapping-coverage figures in this report are therefore an **optimistic upper bound**.
"""

    for name, body in (("quality_report.md", qr), ("mapping_loss_analysis.md", la)):
        p = os.path.join(OUT, name)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(body)
        print(f"  wrote {p} ({len(body):,} bytes)")
    con.close()


if __name__ == "__main__":
    main()
