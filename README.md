# FHIR → OMOP: what survives the mapping?

A pipeline that maps synthetic patient records from **FHIR** into the **OMOP Common Data Model**,
then runs a data quality assessment in SQL to answer one question:

> **What proportion of clinical data survives the mapping, and what exactly is lost?**

The pipeline is not the deliverable. The quantified answer is.

---

## 1. The problem

Interoperability standards are assumed to be lossless. They are not.

FHIR and OMOP were built for different jobs — FHIR to move a patient's record between systems, OMOP
to make populations analysable — and the translation between them silently discards things. Not
through bugs, but through ordinary, defensible mapping decisions: a code system with no target
concept, a field the destination model has no column for, a one-to-many relationship flattened.

Each decision looks reasonable on its own. The aggregate effect is rarely measured, and almost never
reported alongside the dataset it produced.

## 2. The decision this supports

Whether an OMOP-derived dataset is fit for a specific research question — or whether the mapping has
quietly removed the thing you wanted to study.

That is a question you cannot answer from a row count, and this repository exists to show why.

## 3. What it does

```
Synthea (1,112 patients)
   └── FHIR JSON bundles          1,371,624 resources
        └── Python: flatten to DuckDB staging      715,127 rows, 9 tables
             └── SQL: typed views                  timezone conversion, JSON extraction
                  └── SQL: map to OMOP CDM v5.4    6 tables
                       └── SQL: 33 quality checks + loss analysis
```

Python is used **only** to flatten FHIR JSON into staging tables. Every transformation from staging
onward is SQL.

| FHIR resource | → OMOP table | rows |
|---|---|---|
| Patient | `person` | 1,112 |
| Patient.deceasedDateTime | `death` | 112 |
| Encounter | `visit_occurrence` | 60,015 |
| Condition | `condition_occurrence` | 38,668 |
| MedicationRequest | `drug_exposure` | 50,887 |
| Observation | `measurement` | 501,440 |

### The headline figure

**652,122 rows loaded. Zero rejected. 9.35% are actually usable in a concept-based query.**

Every row reconciles. Every conformance check passes. And a researcher asking *"find me the patients
with viral sinusitis"* gets nothing back — not because the patients don't have it, but because the
SNOMED code never became an OMOP concept.

A row count would call this pipeline a complete success. That gap is the finding.

Full detail: [outputs/mapping_loss_analysis.md](outputs/mapping_loss_analysis.md) and
[outputs/quality_report.md](outputs/quality_report.md).

## 4. What I chose not to build, and why

**The full OMOP vocabulary.** The Athena download is several GB. Without it, no SNOMED, RxNorm or
LOINC code can be resolved to a `concept_id`, so every clinical code loads as `concept_id = 0`. That
single decision produces the 9.35% headline.

I could have invented plausible-looking integers and reported 90% coverage. A wrong `concept_id` does
not announce itself — it produces a dataset that passes every structural check and answers research
questions incorrectly. Recording "we could not map this" is a true statement; recording a guess is
not. The unmapped long tail *is* the result, not a gap in it.

**The rest of the CDM.** OMOP has ~40 tables; this builds six. `observation`, `procedure_occurrence`,
`device_exposure` and `immunization` all have obvious FHIR sources in this dataset and are not built.
Consequence: 59,060 survey and social-history Observations are counted as **routed elsewhere**, not
as loss — they belong in `observation`, which is outside scope. Collapsing that into the reject count
would have inflated apparent loss by an order of magnitude.

**Patient address / geography.** `person.location_id` is NULL throughout. Any research question about
place cannot be asked of this dataset.

**Provenance round-tripping.** `*_source_value` is populated everywhere, so a source code can always
be recovered. But there is no path back from an OMOP row to the FHIR bundle it came from beyond the
`xref_*` crosswalk tables.

**Production ETL concerns.** No incremental loads, no change data capture, no orchestration, no
retries. The pipeline is idempotent and rebuilds from scratch in about a minute.

**Real patient data.** Synthea only. See section 7 for why that flatters every number here.

## 5. Quality framework

33 checks in the **OHDSI Data Quality Dashboard** categories — Conformance, Completeness,
Plausibility — plus 6 quantifications that are reported rather than graded.

Every check reports a **denominator**. "142 failures" is not a result; "142 of 8,904 (1.6%)" is. A
check evaluating zero rows reports `NOT_EVALUATED`, never `PASS` — an empty table must not pass a
quality check by vacuous truth.

**The thresholds were committed before any mapping SQL existed** ([eval/quality_checks.md](eval/quality_checks.md),
commit `f334550`, which precedes the first `sql/02_mapping/` commit). The ordering is deliberate: it
proves the standard was set before the results were seen.

Three checks — CMP-04, CMP-05, CMP-06 — now fail at 100%. They were **not relaxed** when the
vocabulary decision was taken. Lowering a threshold because you already know you will miss it is how
a quality framework becomes decoration.

**Result: 28 pass, 5 fail.** Three failures were predicted. Two were not:

- **PLA-10 — 1,175 events dated before the patient's birth. This pipeline's defect.** Every one is
  exactly one day out. Event timestamps are timezone-converted; `Patient.birthDate` is date-only and
  cannot be, so it never moves. Left unfixed and reported, because clamping would erase the evidence.
- **PLA-06 — 102 visits after death. The source's defect.** Spread over 1–14 days, so not a boundary
  artifact. Synthea emits encounters dated after the death it recorded, and the mapping carries them
  through rather than filtering — an ETL that drops the rows its own checks look for makes those
  checks pass by construction.

## 6. What was lost in mapping

### Three buckets, never collapsed

| bucket | rows | meaning |
|---|---|---|
| 1. Structured and computable | 60,986 | real `concept_id`; queryable |
| 2. Structured but not computable | 591,136 | `concept_id = 0`, `*_source_value` kept; **invisible to concept queries** |
| 3. Could not be structured | 0 | in `etl_rejects` |
| — routed elsewhere (not loss) | 59,060 | belongs in OMOP `observation`, out of scope |

Bucket 2 is the one that misleads. It looks like success in a row count and behaves like absence in
an analysis.

### Per domain, with reasons

**Condition → condition_occurrence (38,668).** All 259 SNOMED codes unmapped. `clinicalStatus`
(active/resolved) has no OMOP home at this granularity and survives only in
`condition_status_source_value`. Condition carries two start dates — `onsetDateTime` (used) and
`recordedDate` (not) — and in Synthea they are frequently identical, so choosing wrongly would
produce correct-looking output that never surfaces in testing.

**MedicationRequest → drug_exposure (50,887).** All 251 RxNorm codes unmapped. **Duration is not
recoverable from this source**: FHIR supplies no end date, so `drug_exposure_end_date` is *derived* as
`end = start`. A 90-day prescription and a single dose are indistinguishable in the output. Any
duration analysis on this dataset is invalid.

20% of requests name their drug via `medicationReference` rather than inline. Reading only the inline
form would have lost 17,178 exposures — and lost them non-randomly, since Synthea uses the reference
form for particular administration types. Invisible in aggregate, biased in composition.

**Observation → measurement (501,440 from 485,764 sources).** All 181 in-scope LOINC codes unmapped.
23.7% of Observations carry no `valueQuantity`; 5.4% carry no `value[x]` at all. Blood pressure lives
entirely in `component[]` — a parser reading scalar values drops all 15,672 systolic/diastolic pairs
while reporting no errors. Expanded into separate rows, tracked in `etl_expansion`.

**Encounter → visit_occurrence (60,015).** The best-covered domain at 99.8%, because `v3-ActCode` is a
5-value closed set. The 122 failures are `VR` (virtual) — OMOP's telehealth representation is not part
of the stable CDM concept set and I would not assert an id I cannot attest to. Separately,
`Encounter.type` (SNOMED, e.g. "well child visit") has no OMOP column at that granularity and survives
only in `visit_source_value`.

**Patient → person (1,112).** 98.3% race coverage; the 19 `UNK` values stay at 0 because OMOP has no
standard Race concept meaning "unknown" and inventing one would turn missing data into a positive
claim about a person's race.

### Timezone — the loss nobody looks for

Every Synthea timestamp carries the offset of the **machine that generated it** (`+05:30`,
Asia/Kolkata) rather than the patients' Massachusetts local time. Four records carry `+06:30` —
India observed UTC+6:30 during 1942–45, and the oldest patient was born in 1925.

**318,286 of 754,521 clinical dates (42.18%) fall on a different calendar day** depending on whether
you convert the timezone or truncate the string. The pipeline converts. The magnitude is not
arbitrary: New York is 10.5 hours behind IST, and events spread evenly across a day put 10.5/24 =
43.75% before the boundary.

## 7. What would be needed for real use

**Full vocabulary coverage.** The single highest-value change. Loading Athena's SNOMED, RxNorm and
LOINC tables would move most of bucket 2 into bucket 1 and turn the 9.35% figure into a real coverage
measurement rather than a demonstration of what its absence costs.

**Validation against a real source system.** Everything here is calibrated on Synthea, which is
tidier than real EHR data in ways that flatter every number above:

- one code system per domain — no local codes, no ICD alongside SNOMED
- `coding[]` had length 1 in 9,378 of 9,384 cases; real records routinely carry several codings per
  concept, and choosing between them is a decision this pipeline never had to make
- all 259 Conditions are `encounter-diagnosis`, so the diagnosis / problem-list / symptom ambiguity
  that makes real Condition mapping hard never arises
- zero structural rejects across 695,506 rows

**The coverage figures in this repository are an optimistic upper bound.** That sentence is the most
important one here.

**Provenance and round-tripping**, so an OMOP row can be traced to the FHIR resource that produced it.

**Incremental loads.** This rebuilds from scratch; a real deployment needs change data capture and
late-arriving-data handling.

**A resolution for the birth-date timezone defect** (PLA-10), which needs a birth *time* the source
does not carry — or a documented convention for comparing timezone-less dates against converted
datetimes.

**Consistent handling of post-mortem records** (PLA-06) — a policy decision, not a technical one.

## 8. Run instructions

Requires Java 11+ (17 preferred) and Python 3.9+.

```bash
python -m venv .venv
.venv\Scripts\Activate.ps1          # Windows;  source .venv/bin/activate on Unix
pip install duckdb pandas
```

Download `synthea-with-dependencies.jar` from the
[Synthea releases page](https://github.com/synthetichealth/synthea/releases) into the repo root, then:

```bash
# 1. Generate.  The seed is fixed; this exact command reproduces the dataset.
java -jar synthea-with-dependencies.jar -p 1000 -s 42

# 2. Stage FHIR JSON into DuckDB  (~5 GB of JSON in, 1.8 GB database out)
python src/ingest/stage_fhir.py

# 3. DDL, staging views, mapping, quality checks
python src/ingest/run_sql.py sql/00_ddl sql/01_staging sql/02_mapping sql/03_quality

# 4. Render the reports into outputs/
python src/ingest/export_outputs.py
```

**Seed: 42.** `-p 1000` produces **1,112** patients, not 1,000 — Synthea's `-p` counts *living*
patients and re-rolls slots where a patient died, writing both records. Never reconcile row counts
against the `-p` argument.

`output/` (Synthea, ~5 GB) and `data/` (DuckDB, 1.8 GB) are gitignored. `outputs/` holds the
deliverables and is tracked.

### Layout

```
src/ingest/     explore_fhir.py    inspection, read-only
                stage_fhir.py      FHIR JSON -> DuckDB staging
                run_sql.py         SQL executor
                export_outputs.py  renders outputs/ from the database
sql/00_ddl/     OMOP CDM v5.4, vocabulary, ETL audit tables
sql/01_staging/ typed views: JSON extraction + timezone conversion
sql/02_mapping/ one file per target table
sql/03_quality/ conformance, completeness, plausibility, quantifications, loss
eval/           quality_checks.md  thresholds, committed before any mapping SQL
outputs/        quality_report.md, mapping_loss_analysis.md
NOTES.md        working log: decisions, rejections, surprises
```

---

*Built with AI assistance; all design decisions, evaluation criteria and analysis are mine.*
