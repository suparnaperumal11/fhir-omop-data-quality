# Mapping loss analysis

**What proportion of clinical data survives the mapping, and what exactly is lost?**

Cohort: 1,112 Synthea patients, 1,371,624 FHIR resources, five source resource types
mapped to six OMOP CDM v5.4 tables.

---

## The headline

Of **695,506** source rows in the five in-scope domains:

- **59,060** were routed elsewhere (correctly - see below), not lost
- **0** could not be structured at all
- **652,122** rows loaded to the CDM
- of those, **60,986 are computable** and **591,136 are not**

### 9.35% of loaded rows are actually usable in a concept-based query.

Every row loaded. Nothing was rejected. A row count would report this pipeline as a
complete success, and a researcher running `SELECT ... WHERE condition_concept_id = <viral
sinusitis>` against the result would get **zero rows** - not because the patients do not
have the condition, but because the code never became a concept.

That gap is the finding.

---

## By domain

| domain | source_rows | target_rows | expansion_rows | bucket1_computable | bucket2_not_computable | bucket3_rejected | out_of_scope | pct_computable |
|---|---|---|---|---|---|---|---|---|
| Observation -> measurement | 544,824 | 501,440 | 15,676 | 0 | 501,440 | 0 | 59,060 | 0.0 |
| Encounter -> visit_occurrence | 60,015 | 60,015 | 0 | 59,893 | 122 | 0 | 0 | 99.8 |
| MedicationRequest -> drug_exposure | 50,887 | 50,887 | 0 | 0 | 50,887 | 0 | 0 | 0.0 |
| Condition -> condition_occurrence | 38,668 | 38,668 | 0 | 0 | 38,668 | 0 | 0 | 0.0 |
| Patient -> person | 1,112 | 1,112 | 0 | 1,093 | 19 | 0 | 0 | 98.29 |

Reconciliation holds in every domain:

```
source = mapped + rejected + out_of_scope
target = mapped + expansion
```

---

## The three buckets

**1. Structured and computable - 60,986 rows.** Almost entirely `visit_occurrence`
(59,893) and `person` (1,093). These are the domains whose vocabularies are part of the
CDM specification itself rather than a downloadable release.

**2. Structured but not computable - 591,136 rows.** Every condition, every drug
exposure, every measurement. They are present, they reconcile, they pass every
conformance check, and `*_source_value` preserves the original code so a later
vocabulary load could resolve them retrospectively. They are invisible to any
concept-based cohort query.

This bucket is the one that misleads. It looks like success in a row count and behaves
like absence in an analysis.

**3. Could not be structured - 0 rows.** Zero. Synthea emits structurally
well-formed FHIR: every resource had a subject that resolved, a parseable date, and a
code. Real EHR data does not behave this way, and a reject count of zero should be read
as a property of the source, not evidence that the reject path is sound.

**Routed elsewhere (not loss) - 59,060 rows.** Survey and social-history Observations
belong in OMOP's `observation` table, which this project does not build. Counting them
as rejects would have inflated the apparent loss by an order of magnitude. They were not
lost; they were sent somewhere we do not go.

---

## Vocabulary coverage, by code and by row

| domain | distinct_codes | distinct_codes_mapped | pct_codes_mapped | rows_total | rows_mapped | pct_rows_mapped |
|---|---|---|---|---|---|---|
| Measurement (LOINC) | 181 | 0 | 0.0 | 501,440 | 0 | 0.0 |
| Visit (v3-ActCode) | 5 | 4 | 80.0 | 60,015 | 59,893 | 99.8 |
| Drug (RxNorm) | 251 | 0 | 0.0 | 50,887 | 0 | 0.0 |
| Condition (SNOMED) | 259 | 0 | 0.0 | 38,668 | 0 | 0.0 |
| Person ethnicity (OMB) | 2 | 2 | 100.0 | 1,112 | 1,112 | 100.0 |
| Person race (OMB) | 6 | 5 | 83.3 | 1,112 | 1,093 | 98.3 |

Reported both ways deliberately. The two can diverge sharply, and quoting only the
flattering one misrepresents coverage.

---

## The long tail - top unmapped codes by row count

| domain | rank | code | display | n_rows |
|---|---|---|---|---|
| Condition (SNOMED) | 1 | 314529007 | Medication review due (situation) | 7,966 |
| Condition (SNOMED) | 2 | 73595000 | Stress (finding) | 2,936 |
| Condition (SNOMED) | 3 | 66383009 | Gingivitis (disorder) | 2,887 |
| Condition (SNOMED) | 4 | 160903007 | Full-time employment (finding) | 2,730 |
| Condition (SNOMED) | 5 | 160904001 | Part-time employment (finding) | 1,687 |
| Condition (SNOMED) | 6 | 444814009 | Viral sinusitis (disorder) | 1,122 |
| Condition (SNOMED) | 7 | 422650009 | Social isolation (finding) | 1,074 |
| Condition (SNOMED) | 8 | 423315002 | Limited social contact (finding) | 1,058 |
| Condition (SNOMED) | 9 | 741062008 | Not in labor force (finding) | 928 |
| Condition (SNOMED) | 10 | 18718003 | Gingival disease (disorder) | 838 |
| Drug (RxNorm) | 1 | 205923 | 1 ML Epoetin Alfa 4000 UNT/ML Injection [Epogen] | 6,058 |
| Drug (RxNorm) | 2 | 310798 | Hydrochlorothiazide 25 MG Oral Tablet | 4,043 |
| Drug (RxNorm) | 3 | 106892 | insulin isophane, human 70 UNT/ML / insulin, regular, human 30 UNT/ML Injectable Suspension [Humulin] | 4,031 |
| Drug (RxNorm) | 4 | 314076 | lisinopril 10 MG Oral Tablet | 3,535 |
| Drug (RxNorm) | 5 | 308136 | amLODIPine 2.5 MG Oral Tablet | 3,169 |
| Drug (RxNorm) | 6 | 1535362 | sodium fluoride 0.0272 MG/MG Oral Gel | 2,895 |
| Drug (RxNorm) | 7 | 1736854 | Cisplatin 50 MG Injection | 2,677 |
| Drug (RxNorm) | 8 | 860975 | 24 HR Metformin hydrochloride 500 MG Extended Release Oral Tablet | 2,204 |
| Drug (RxNorm) | 9 | 583214 | Paclitaxel 100 MG Injection | 2,191 |
| Drug (RxNorm) | 10 | 1049625 | Acetaminophen 325 MG / Oxycodone Hydrochloride 10 MG Oral Tablet [Percocet] | 1,141 |
| Measurement (LOINC) | 1 | 72514-3 | Pain severity - 0-10 verbal numeric rating [Score] - Reported | 23,702 |
| Measurement (LOINC) | 2 | 8462-4 | Diastolic Blood Pressure | 15,672 |
| Measurement (LOINC) | 3 | 8480-6 | Systolic Blood Pressure | 15,672 |
| Measurement (LOINC) | 4 | 29463-7 | Body Weight | 14,939 |
| Measurement (LOINC) | 5 | 8867-4 | Heart rate | 14,730 |
| Measurement (LOINC) | 6 | 9279-1 | Respiratory rate | 14,730 |
| Measurement (LOINC) | 7 | 8302-2 | Body Height | 14,375 |
| Measurement (LOINC) | 8 | 39156-5 | Body mass index (BMI) [Ratio] | 13,298 |
| Measurement (LOINC) | 9 | 33914-3 | Glomerular filtration rate [Volume Rate/Area] in Serum or Plasma by Creatinine-based formula (MDRD)/1.73 sq M | 11,125 |
| Measurement (LOINC) | 10 | 49765-1 | Calcium [Mass/volume] in Blood | 8,931 |

---

## Row multiplication

| mapping | source_rows_expanded | target_rows_produced | additional_rows |
|---|---|---|---|
| Observation -> measurement | 15,674 | 31,350 | 15,676 |

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
