# Quality checks — defined before any mapping SQL exists

**Status:** thresholds fixed on 2026-09-07, before a single mapping query was written.
The commit timestamp on this file precedes the first commit touching `sql/02_mapping/`.
That ordering is the point: it proves the standard was set before the results were seen.

Framework: **OHDSI Data Quality Dashboard** categories — Conformance, Completeness, Plausibility.
No alternatives invented.

Scope: the five target tables only — `person`, `visit_occurrence`, `condition_occurrence`,
`drug_exposure`, `measurement`.

---

## How every check reports

Each check is one SQL query returning exactly these columns:

| column | meaning |
|---|---|
| `check_id` | e.g. `CON-03` |
| `check_name` | short description |
| `category` | Conformance / Completeness / Plausibility |
| `target` | table.field under test |
| `rows_evaluated` | **denominator** |
| `rows_failed` | numerator |
| `pct_failed` | `rows_failed / rows_evaluated` |
| `threshold_pct` | the day-1 number below |
| `status` | PASS / FAIL |

**A result is never reported without its denominator.** "142 failures" is not a result;
"142 of 8,904 (1.6%)" is. A check whose denominator is 0 reports `NOT_EVALUATED`, never `PASS` —
an empty table must not be able to pass a quality check by vacuous truth.

---

## Conformance

Types correct, concept IDs valid, required fields present, foreign keys resolve.

| ID | Check | Target | Threshold (max % failed) |
|---|---|---|---|
| CON-01 | `person_id` is NOT NULL and unique | person | 0% |
| CON-02 | Primary key unique in every target table | all five | 0% |
| CON-03 | `person_id` on every clinical row resolves to a `person` | 4 clinical tables | 0% |
| CON-04 | `visit_occurrence_id`, where non-NULL, resolves to a visit | 3 clinical tables | 0% |
| CON-05 | `gender_concept_id` ∈ {8507, 8532, 0} | person | 0% |
| CON-06 | Every `*_concept_id` is NOT NULL (0 is permitted and meaningful; NULL is not) | all five | 0% |
| CON-07 | Every date column holds a valid DATE (no unparseable strings) | all five | 0% |
| CON-08 | `*_datetime` falls on the same calendar day as its `*_date` | all five | 0% |
| CON-09 | `*_source_value` is populated wherever the source carried a code | all five | 0% |
| CON-10 | `visit_concept_id` ∈ the OMOP Visit domain | visit_occurrence | 0% |
| CON-11 | `measurement.unit_concept_id` is NOT NULL where a UCUM unit was present | measurement | 0% |

All Conformance thresholds are **0%**. These are structural guarantees the ETL controls completely;
any failure is a bug in our code, not a property of the source. CON-06 deserves emphasis: an unmapped
code must arrive as `concept_id = 0`, never NULL, so that "we could not map this" is a recorded fact
rather than an absence.

CON-08 is the timezone check. It is set to 0% and is expected to **pass only because** we convert to
America/New_York before splitting date from datetime; the naive alternative would fail it. See
Quantification Q-01.

---

## Completeness

Missingness by field and by domain. Thresholds here are **targets, not guarantees** — a failure is a
finding about the source or about vocabulary coverage, not necessarily a defect.

| ID | Check | Target | Threshold (max % missing/unmapped) |
|---|---|---|---|
| CMP-01 | `birth_datetime` populated | person | 0% |
| CMP-02 | `race_concept_id` ≠ 0 | person | 5% |
| CMP-03 | `ethnicity_concept_id` ≠ 0 | person | 5% |
| CMP-04 | `condition_concept_id` ≠ 0 | condition_occurrence | 20% |
| CMP-05 | `drug_concept_id` ≠ 0 | drug_exposure | 20% |
| CMP-06 | `measurement_concept_id` ≠ 0 | measurement | 30% |
| CMP-07 | `visit_concept_id` ≠ 0 | visit_occurrence | 5% |
| CMP-08 | `value_as_number` or `value_as_concept_id` populated | measurement | 10% |
| CMP-09 | `care_site_id` populated | visit_occurrence | 10% |
| CMP-10 | `provider_id` populated | visit_occurrence | 10% |

**Why these numbers.** Race/ethnicity (5%) come from a closed OMB category list — near-total mapping
is achievable and anything worse indicates an ETL fault. Condition and drug (20%) reflect hand-mapped
vocabulary against a long tail we expect to miss; the full Athena download is deliberately out of
scope. Measurement is loosest (30%) because LOINC is the largest and most varied code set here.
`care_site_id`/`provider_id` (10%) assume the conditional-reference resolution works; if we fall back
to NULL-and-report these fail at 100% and that failure is the honest record of the fallback.

These thresholds are set to be **failable**. A framework calibrated so everything passes measures
nothing.

---

## Plausibility

Clinically impossible or internally contradictory values.

| ID | Check | Target | Threshold (max % failed) |
|---|---|---|---|
| PLA-01 | Age at any event < 120 years | all clinical | 0% |
| PLA-02 | `death_date` ≥ `birth_datetime` | person | 0% |
| PLA-03 | No `condition_start_date` after `death_date` | condition_occurrence | 0% |
| PLA-04 | No `drug_exposure_start_date` after `death_date` | drug_exposure | 0% |
| PLA-05 | No `measurement_date` after `death_date` | measurement | 0% |
| PLA-06 | No `visit_start_date` after `death_date` | visit_occurrence | 0% |
| PLA-07 | `visit_end_date` ≥ `visit_start_date` | visit_occurrence | 0% |
| PLA-08 | `condition_end_date` ≥ `condition_start_date`, where both present | condition_occurrence | 0% |
| PLA-09 | `drug_exposure_end_date` ≥ `drug_exposure_start_date` | drug_exposure | 0% |
| PLA-10 | Every event date ≥ the person's `birth_datetime` | all clinical | 0% |
| PLA-11 | Lab `value_as_number` within physiological range (table below) | measurement | 1% |
| PLA-12 | `measurement_date` falls within its linked visit's period | measurement | 5% |

PLA-11 ranges — deliberately wide, to catch impossible values rather than merely unusual ones:

| LOINC | Measure | Unit | Plausible range |
|---|---|---|---|
| 8302-2 | Body height | cm | 30 – 250 |
| 29463-7 | Body weight | kg | 0.5 – 350 |
| 39156-5 | BMI | kg/m2 | 8 – 100 |
| 8480-6 | Systolic BP | mm[Hg] | 40 – 300 |
| 8462-4 | Diastolic BP | mm[Hg] | 20 – 200 |
| 8867-4 | Heart rate | /min | 20 – 300 |
| 9279-1 | Respiratory rate | /min | 4 – 80 |
| 2339-0 | Glucose | mg/dL | 10 – 1500 |
| 2160-0 | Creatinine | mg/dL | 0.1 – 25 |
| 718-7 | Haemoglobin | g/dL | 2 – 25 |

PLA-11 gets 1% rather than 0% because a synthetic generator may legitimately emit extreme values, and
a genuine outlier is not an ETL defect. PLA-12 gets 5% because observations can legitimately be
recorded outside a visit window.

PLA-01 through PLA-10 are at 0%: each is an internal contradiction that no correct pipeline should
produce. PLA-03/04/05/06 exercise the 112 deceased patients in the cohort.

---

## Quantifications (reported, not pass/fail)

Numbers that are findings in their own right. These have no threshold because there is no correct
value to hold them to — the measurement *is* the result.

| ID | Quantification |
|---|---|
| **Q-01** | **Rows whose calendar date shifts by one day** when the source timestamp is converted from its recorded `+05:30` offset to America/New_York, versus naive string truncation. Reported per domain, as a count and a percentage. This is what happens when an ETL ignores timezone, measured rather than asserted. |
| Q-02 | Distinct source codes per domain: how many, how many hand-mapped, what share of *rows* the mapped ones cover. Coverage by row and by distinct code reported separately — they differ sharply, and quoting only the flattering one would misrepresent it. |
| Q-03 | Top 25 unmapped source codes per domain, by row count, with display names. The long tail is the finding. |
| Q-04 | `coding[]` arrays with length > 1, where we took `[0]` and discarded the rest. |
| Q-05 | Row multiplication: source rows expanding to >1 target row (BP panels → systolic + diastolic). |
| Q-06 | Granularity loss on race/ethnicity: distinct source values in vs distinct OMOP concepts out. |

---

## Reconciliation identity

Row counts must reconcile per domain. Blood-pressure expansion means the naive identity does not
hold, so it is stated explicitly with a multiplication term:

```
source_rows  =  mapped_source_rows  +  rejected_rows  +  out_of_scope_rows
target_rows  =  mapped_source_rows  +  expansion_rows
```

- `rejected_rows` — could not be mapped; every one has a row in `etl_rejects` with a reason code.
- `out_of_scope_rows` — **correctly routed elsewhere**, not lost. Survey and social-history
  Observations belong in OMOP `observation`, which is outside this project's five tables.
  Counted separately and never folded into rejects: doing so would overstate the loss figure.
- `expansion_rows` — additional target rows from legitimate one-to-many mapping. Tracked in its own
  column so an expansion can never be mistaken for a duplicate, nor silently inflate the mapped count.

An unexplained difference on either line is a failure of the pipeline, not a rounding artifact.

---

## The three buckets

Loss is reported in three buckets, never collapsing the last two:

1. **Structured and computable** — mapped to a real OMOP `concept_id`, queryable by a researcher.
2. **Structured but not computable** — carried across with `concept_id = 0` and a populated
   `*_source_value`. The data is present and auditable but will not appear in a concept-based cohort
   query. It looks like success in a row count and behaves like absence in an analysis.
3. **Could not be structured at all** — no target column exists; recorded in `etl_rejects` only.

Bucket 2 is the one that misleads. A pipeline reporting "98% of rows loaded" while most carry
`concept_id = 0` has moved data without making it usable, and the distinction between buckets 1 and 2
is the difference between a dataset that answers a research question and one that merely appears to.
