# Quality report

Generated from `data/fhir_omop.duckdb`. Every figure is read from a table produced by
the SQL in `sql/03_quality/`; nothing is recomputed here.

Cohort: 1,112 Synthea patients (`-p 1000 -s 42`; 1,000 living, 112 deceased).

**28 checks pass, 5 fail.**

Three of the failures were predicted before the mapping was written. Two were not, and
those two are the interesting ones - one is a defect in this pipeline, one is a defect
in the source. Telling them apart is what the framework is for.

---

## Results

| check_id | check_name | category | rows_evaluated | rows_failed | pct_failed | threshold | status |
|---|---|---|---|---|---|---|---|
| CMP-01 | birth_datetime populated | Completeness | 1,112 | 0 | 0.0 | 0 | PASS |
| CMP-02 | race_concept_id mapped (not 0) | Completeness | 1,112 | 19 | 1.709 | 5 | PASS |
| CMP-03 | ethnicity_concept_id mapped (not 0) | Completeness | 1,112 | 0 | 0.0 | 5 | PASS |
| CMP-07 | visit_concept_id mapped (not 0) | Completeness | 60,015 | 122 | 0.203 | 5 | PASS |
| CMP-08 | measurement has a value (number or concept) | Completeness | 501,440 | 131 | 0.026 | 10 | PASS |
| CMP-09 | care_site_id populated | Completeness | 60,015 | 0 | 0.0 | 10 | PASS |
| CMP-10 | provider_id populated | Completeness | 60,015 | 0 | 0.0 | 10 | PASS |
| CON-01 | person_id is NOT NULL and unique | Conformance | 1,112 | 0 | 0.0 | 0 | PASS |
| CON-02 | Primary key unique in every target table | Conformance | 652,234 | 0 | 0.0 | 0 | PASS |
| CON-03 | person_id on clinical rows resolves to a person | Conformance | 651,010 | 0 | 0.0 | 0 | PASS |
| CON-04 | Non-NULL visit_occurrence_id resolves to a visit | Conformance | 590,995 | 0 | 0.0 | 0 | PASS |
| CON-05 | gender_concept_id in {8507, 8532, 0} | Conformance | 1,112 | 0 | 0.0 | 0 | PASS |
| CON-06 | Required *_concept_id columns are NOT NULL | Conformance | 652,122 | 0 | 0.0 | 0 | PASS |
| CON-07 | Source datetime strings parse to a valid timestamp | Conformance | 754,521 | 0 | 0.0 | 0 | PASS |
| CON-08 | *_datetime falls on the same day as *_date | Conformance | 711,137 | 0 | 0.0 | 0 | PASS |
| CON-09 | *_source_value populated where a source code existed | Conformance | 590,995 | 0 | 0.0 | 0 | PASS |
| CON-10 | visit_concept_id in the Visit domain | Conformance | 60,015 | 0 | 0.0 | 0 | PASS |
| CON-11 | unit_concept_id set where a unit was supplied | Conformance | 423,681 | 0 | 0.0 | 0 | PASS |
| PLA-01 | Age at event < 120 years | Plausibility | 651,010 | 0 | 0.0 | 0 | PASS |
| PLA-02 | death_date on or after birth | Plausibility | 112 | 0 | 0.0 | 0 | PASS |
| PLA-03 | No condition starting after death | Plausibility | 5,725 | 0 | 0.0 | 0 | PASS |
| PLA-04 | No drug exposure starting after death | Plausibility | 15,543 | 0 | 0.0 | 0 | PASS |
| PLA-05 | No measurement after death | Plausibility | 125,964 | 0 | 0.0 | 0 | PASS |
| PLA-07 | visit_end_date >= visit_start_date | Plausibility | 60,015 | 0 | 0.0 | 0 | PASS |
| PLA-08 | condition_end_date >= condition_start_date | Plausibility | 28,927 | 0 | 0.0 | 0 | PASS |
| PLA-09 | drug_exposure_end_date >= start_date | Plausibility | 50,887 | 0 | 0.0 | 0 | PASS |
| PLA-11 | Lab/vital value within physiological range | Plausibility | 122,267 | 5 | 0.004 | 1 | PASS |
| PLA-12 | measurement_date within its linked visit period | Plausibility | 501,440 | 54 | 0.011 | 5 | PASS |
| CMP-04 | condition_concept_id mapped (not 0) | Completeness | 38,668 | 38,668 | 100.0 | 20 | FAIL |
| CMP-05 | drug_concept_id mapped (not 0) | Completeness | 50,887 | 50,887 | 100.0 | 20 | FAIL |
| CMP-06 | measurement_concept_id mapped (not 0) | Completeness | 501,440 | 501,440 | 100.0 | 30 | FAIL |
| PLA-06 | No visit starting after death | Plausibility | 11,933 | 102 | 0.855 | 0 | FAIL |
| PLA-10 | Every event on or after birth | Plausibility | 651,010 | 1,175 | 0.18 | 0 | FAIL |

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

| domain | rows_evaluated | rows_shifted_one_day | pct_shifted |
|---|---|---|---|
| Observation.effective | 544,824 | 231,077 | 42.41 |
| Encounter.end | 60,015 | 24,754 | 41.25 |
| Encounter.start | 60,015 | 25,239 | 42.05 |
| MedicationRequest.authoredOn | 50,887 | 21,030 | 41.33 |
| Condition.onset | 38,668 | 16,141 | 41.74 |
| Patient.deceased | 112 | 45 | 40.18 |

The magnitude is not arbitrary: New York is 10.5 hours behind IST, and events spread
evenly across a day put 10.5/24 = 43.75% before the boundary. The observed 42% agrees,
which is evidence the effect is real rather than a parsing artifact.

---

## Q-04 - multi-coding

`coding[]` arrays where more than one coding was present and we took `[0]`, discarding
the rest.

| domain | rows_total | rows_multi_coding |
|---|---|---|
| Condition | 38,668 | 0 |
| Observation | 768,740 | 4,618 |

Small here. It would not be small on real EHR data, where a single concept routinely
carries local, SNOMED and ICD codings side by side.

---

## Q-06 - demographic granularity

| field | distinct_source_values | distinct_target_concepts | source_values_lost |
|---|---|---|---|
| race | 6 | 6 | 1 |
| ethnicity | 2 | 2 | 0 |
| gender | 2 | 2 | 0 |

Race loses one of six source values (`UNK`, 19 patients), left at `concept_id = 0`
because OMOP has no standard Race concept meaning "unknown" and inventing one would
turn missing data into a positive claim about a person's race.

This understates real-world granularity loss. Synthea emits only the five OMB
categories; US Core also permits a `detailed` race sub-extension carrying finer
granularity, which is absent here. On real US Core data the collapse to OMOP's five
Race concepts would be substantially lossier.
