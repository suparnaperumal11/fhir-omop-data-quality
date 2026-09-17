# Dataset fitness report

**For:** a research analyst who has been handed this OMOP dataset and needs to decide whether it
can answer their research question — not someone evaluating how the pipeline was built.

---

## 1. What was assessed

Source: 1,112 synthetic patients (Synthea, seed 42) as FHIR bundles. Target: six OMOP CDM v5.4
tables — `person`, `death`, `visit_occurrence`, `condition_occurrence`, `drug_exposure`,
`measurement`. Assessment: 33 automated checks (OHDSI Data Quality Dashboard categories —
Conformance, Completeness, Plausibility) plus row-level reconciliation and vocabulary coverage
analysis, run against the loaded database.

## 2. Executive finding

**Every conformance check passed. Every row reconciles. Zero rows were rejected. And 9.35% of the
loaded data is answerable by a standard concept-based query.**

Structural success and research fitness are different questions, and this dataset answers them
differently. A row count alone would call the mapping a complete success. The 9.35% is
concentrated almost entirely in visits and demographics. For conditions, drugs and measurements,
the figure is zero.

28 of 33 checks passed. Two failures were not predicted in advance and matter more than the count
implies (§3, §6).

## 3. What passed

- **All 11 Conformance checks passed at 0% failure** — primary keys unique, foreign keys resolve,
  required fields present, dates parse, `*_source_value` populated wherever a source code existed.
- **Reconciliation holds exactly, in every domain, with zero residual**: source rows = mapped +
  rejected + out-of-scope; target rows = mapped + expansion.
- **Zero rows rejected**, across 695,506 source rows in the five mapped domains.
- Conformance passing is necessary but **not evidence of fitness on its own** — the database
  schema requires certain fields to be non-null, so a row that couldn't supply one was diverted
  before conformance was ever checked. Conformance measures what got in, not what it's worth.

## 4. What was lost, and what became analytically limited

Four categories, kept separate on purpose — collapsing any two of them into one number
misrepresents the dataset.

| Category | Rows | Denominator | What it means here |
|---|---|---|---|
| **Rejected** — could not be loaded at all | 0 | 695,506 source rows | Genuinely zero. Read this as a property of Synthea's clean output, not proof the reject path works (§6). |
| **Deliberately out of scope** | 59,060 | 544,824 Observations (10.8%) | Survey and social-history Observations belong in OMOP's `observation` table, which this build does not include. Not lost — routed nowhere, on purpose. |
| **Target model cannot represent** | not row-countable | — | `Condition.clinicalStatus`/`verificationStatus` (active vs. resolved) has no structured OMOP column at this granularity — text-only in `condition_status_source_value`. Same for Encounter's SNOMED visit-type detail (e.g. "well-child visit") — survives only in `visit_source_value`. |
| **Structured but not concept-computable** | 591,136 | 652,122 loaded rows (90.6%) | The data is present, reconciles, and passes every conformance check. It is invisible to any query filtered by a standard OMOP `concept_id`. |

The fourth row is the one that misleads a row-count read of this dataset. By domain, the loaded
rows that carry a real, queryable `concept_id` are:

| Domain | Loaded rows | Concept-computable | % |
|---|---|---|---|
| `visit_occurrence` | 60,015 | 59,893 | 99.8% |
| `person` (race) | 1,112 | 1,093 | 98.3% |
| `condition_occurrence` | 38,668 | 0 | 0.0% |
| `drug_exposure` | 50,887 | 0 | 0.0% |
| `measurement` | 501,440 | 0 | 0.0% |

## 5. What this dataset can and cannot answer

**Supported now:**
- Cohort definition by **visit type, timing, and count** — ambulatory, emergency, inpatient, home
  health (99.8% concept-computable).
- Cohort definition by **demographics** — gender (100%), ethnicity (100%), race at OMB-category
  granularity (98.3%; the missing 1.7% is 19 patients coded `UNK`, deliberately left unmapped
  rather than assigned a fabricated "known unknown" concept).

**Not supported as delivered:**
- **A standard cohort query on any condition, drug, or lab/vital concept returns nothing usable.**
  Concretely: `SELECT ... WHERE condition_concept_id = <viral sinusitis>` returns zero rows,
  despite 1,122 source rows coding exactly that (SNOMED 444814009) — the code loaded, but never
  became a concept. The same is true for every condition (259 distinct SNOMED codes), every drug
  (251 RxNorm codes), and every measurement (181 LOINC codes) in this dataset — 0% resolved to a
  standard concept in each domain.
- **Drug exposure duration or adherence analysis is invalid.** FHIR's `MedicationRequest` carries
  no end date; `drug_exposure_end_date` is derived as `start = end`. A 90-day prescription and a
  single dose look identical.
- **Any question involving patient location cannot be asked.** `person.location_id` is NULL for
  all 1,112 patients; geography was not mapped.
- **Social determinants and survey data are not in this database at all** — not bucket-2, not
  queryable by any means, because the `observation` table wasn't built. 59,060 rows exist in the
  source and nowhere in this OMOP instance.
- **A cohort filtered on current condition status (active vs. resolved) cannot use a standard
  field** — it exists only as text in `condition_status_source_value`.

**Partial exception — blood pressure.** Unlike the rest of `measurement`, systolic and diastolic
values are present as separate rows (15,672 each), not silently dropped: the `component[]` array
was explicitly expanded rather than skipped. The row is there and correctly split — it just
carries `concept_id = 0` like the rest of the domain, so it's retrievable by matching the raw
LOINC `source_value`, not by a standard concept-based query.

Two data-quality issues to be aware of before trusting date-based results: **1,175 of 651,010
clinical events (0.18%) are timestamped one day before the patient's recorded birth** — a
pipeline arithmetic artifact, not a clinical fact (§6) — and **102 of 11,933 visits (0.86%) start
after the patient's recorded death date**, which is a genuine defect in the source data, carried
through rather than filtered out.

## 6. Limitations

- **Synthetic data.** Every coverage figure in this report is an **optimistic upper bound**, for
  specific, measured reasons: one code system per domain (no local codes competing with SNOMED/
  RxNorm/LOINC), `coding[]` arrays of length >1 in only 6 of 9,384 cases, all 259 Conditions
  filed as a single, unambiguous type, and zero structurally invalid rows across 695,506 source
  rows. Real clinical source data does none of these things reliably.
- **Vocabulary scope.** No standard OMOP vocabulary (SNOMED/RxNorm/LOINC-to-concept mapping) was
  loaded — that download is several gigabytes and was out of scope. Only Visit type codes and
  race/ethnicity (both small, closed code sets) were hand-mapped. This is the direct cause of the
  0% concept-computable figures in §5.
- **Six-table scope.** Only `person`, `death`, `visit_occurrence`, `condition_occurrence`,
  `drug_exposure`, and `measurement` were built. `observation`, `procedure_occurrence`,
  `device_exposure`, and `immunization` were not — anything that would live there (survey data,
  procedures, devices, immunizations) is absent from this database regardless of source quality.
- **The timezone defect.** Every source timestamp carries the offset of the machine that generated
  it, not the patients' local time; the pipeline converts to America/New_York before splitting
  date from datetime. That conversion is correct for clinical event timestamps, but
  `Patient.birthDate` is date-only and cannot be converted, so it doesn't move — producing the
  1,175 pre-birth events in §5. This is a defect in this pipeline's handling of a mixed
  timezone-aware/timezone-naive schema, not a defect in the source data.
- **Read the coverage numbers with the confidence they deserve.** The figures that are
  cross-checked against an independent calculation (the 9.35% headline, the 42% timezone-shift
  rate, the blood-pressure row counts) are trustworthy. The single-query rankings — top unmapped
  codes, per-domain distinct-code counts — carry only the reliability of one query each; one such
  query was found to be inflated by roughly 1,700x before correction, caught only because the
  error was large enough to be obviously wrong.

## 7. Decision

This dataset can reasonably support **visit-utilization analysis and demographic cohort
definition** now, on the evidence above — those are the domains that are both structurally loaded
and concept-computable.

It cannot currently support **any research question that requires identifying patients by a
specific condition, drug, or lab/vital finding** — which is most of what a clinical dataset is
usually for. The data for those questions is present in the database but not reachable through a
standard concept query.

What would change this: loading the standard OMOP vocabulary (SNOMED, RxNorm, LOINC) to resolve
`concept_id` for the three 0%-computable domains would be the single highest-value change and
would move most of the 591,136 not-computable rows into computable ones. Separately, and
independently: building the `observation` table would restore survey/social-history data;
mapping `person.location_id` would enable geographic questions; resolving the birth-datetime
timezone inconsistency needs either a birth time (not present in this source) or an explicit,
documented convention for comparing a timezone-naive date against converted datetimes.

## 8. Evidence

| Claim | Source |
|---|---|
| 652,122 loaded, 0 rejected, 9.35% computable | `outputs/mapping_loss_analysis.md` §"The headline"; `sql/03_quality/50_loss_analysis.sql` |
| Three/four-way loss breakdown, by-domain table | `outputs/mapping_loss_analysis.md` §"By domain", §"The three buckets" |
| 28 pass / 5 fail, full check results | `outputs/quality_report.md` §"Results"; `eval/quality_checks.md` |
| Conformance 11/11, zero rejects across 695,506 rows | `outputs/quality_report.md` §"What the passing checks do and do not tell you"; `sql/03_quality/10_conformance.sql` |
| Vocabulary coverage by code and by row | `outputs/mapping_loss_analysis.md` §"Vocabulary coverage"; `sql/03_quality/40_quantifications.sql` |
| Viral sinusitis / top unmapped codes | `outputs/mapping_loss_analysis.md` §"The long tail" |
| Drug duration derivation (`end = start`) | `outputs/mapping_loss_analysis.md` §"Would the absence change a research conclusion?"; `NOTES.md` decision 5 |
| Blood pressure expansion, 15,672 systolic/diastolic | `outputs/quality_report.md` §"Q-01"/row-multiplication cross-check; `outputs/mapping_loss_analysis.md` §"Row multiplication"; `NOTES.md` decision 2 |
| Geography absent (`location_id` NULL) | `README.md` §4; `NOTES.md` Step 4, "`location` is not created" |
| Social/survey data out of scope, 59,060 rows | `outputs/mapping_loss_analysis.md` §"Routed elsewhere"; `NOTES.md` decision 6 |
| Condition status / encounter-type detail not representable | `README.md` §6, per-domain notes |
| PLA-10 (1,175 pre-birth events) and PLA-06 (102 post-death visits) | `outputs/quality_report.md` §"The two unexpected failures"; `sql/03_quality/30_plausibility.sql` |
| Race coverage, 19 `UNK` at concept_id 0 | `outputs/quality_report.md` §"Q-06"; `eval/quality_checks.md` CMP-02 |
| Synthea-flattery / optimistic-upper-bound reasoning | `README.md` §7; `NOTES.md` Step 1 |
| Single-query reliability caveat (Q-03 cartesian error) | `README.md` §"How much should you trust these numbers?" |
