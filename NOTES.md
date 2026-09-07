# NOTES

Working log: what I decided, what I rejected, what surprised me.
Feeds README sections 4 (what I chose not to build) and 6 (what was lost in mapping).

---

## Step 1 — Generate and inspect

**Command:** `java -jar synthea-with-dependencies.jar -p 5 -s 42`
Synthea 3.x, Java 21 (Temurin), Massachusetts default location. Output: `output/fhir/`.
Inspection script: `src/ingest/explore_fhir.py` (read-only; walks bundles recursively rather than
assuming paths, so it reports what is present rather than what I expected).

Sample: 8 files — 6 patient bundles, plus `hospitalInformation*.json` (25 Organization, 26 Location)
and `practitionerInformation*.json` (25 Practitioner, 25 PractitionerRole).
**7,594 resources** across the 6 patient bundles.

### Surprise 1 — `-p 5` produced 6 patients, not 5

Synthea log: `Records: total=6, alive=5, dead=1`. `-p` targets *living* patients; when a patient dies
during simulation Synthea re-rolls the slot and writes **both** records. Two of our patients share
birthDate 1958-10-20 and city Peabody — the dead original (Jona712) and its living replacement
(Maureen515). They are distinct people with distinct IDs, not duplicates.

*Consequence:* row-count reconciliation must be driven by what is in the bundles, never by the `-p`
argument. At `-p 1000` expect ~1000 living plus an unknown number of deceased. Useful side effect:
we get deceased patients for free, which the death-plausibility checks need.

### Bundle shape

Top-level keys are exactly `resourceType`, `type`, `entry` — no `meta`, no `total`, no `link`, so
there is no pagination to handle. Every entry has exactly `fullUrl`, `resource`, `request`.
`type` is `transaction`; the `request` block is POST routing metadata for a FHIR server and is
irrelevant to us. **All 7,594 `fullUrl` values are `urn:uuid:<id>`.**

Resource counts (patient bundles), with per-bundle min..max:

| resourceType | count | per bundle |
|---|---|---|
| Observation | 2936 | 62..1763 |
| Procedure | 1112 | 54..369 |
| DiagnosticReport | 712 | 22..299 |
| Claim | 584 | 16..201 |
| ExplanationOfBenefit | 584 | 16..201 |
| Encounter | 364 | 12..124 |
| DocumentReference | 364 | 12..124 |
| Condition | 259 | 13..102 |
| MedicationRequest | 220 | 3..90 |
| SupplyDelivery | 162 | 9..74 |
| Immunization | 79 | 7..15 |
| Device | 48 | 1..17 |
| Medication | 44 | 2..23 |
| MedicationAdministration | 44 | 2..23 |
| ImagingStudy | 25 | 2..9 |
| CareTeam | 21 | 1..8 |
| CarePlan | 21 | 1..8 |
| Patient | 6 | 1..1 |
| Provenance | 6 | 1..1 |
| AllergyIntolerance | 3 | **0**..3 |

Per-bundle counts vary by ~30x (62 to 1763 Observations). Nothing may assume a per-patient size.
AllergyIntolerance is absent from some patients entirely — a parser that indexes rather than
iterating resource types will crash or silently skip.

### Where clinical codes live

`code.coding[]` is an array, but in this sample it is **length 1 in all but 6 of 9,384 CodeableConcepts**
across Observation. So `coding[0]` is right ~99.9% of the time — and I will still record the array
length, because "we took the first of N" is exactly the kind of silent loss this project exists to count.

Code system per target resource:

| Resource | Path | System |
|---|---|---|
| Patient | `extension[us-core-race].ombCategory.valueCoding` | `urn:oid:2.16.840.1.113883.6.238` (CDC Race & Ethnicity) |
| Patient | `maritalStatus` | `v3-MaritalStatus` |
| Encounter | `type[].coding[]` | SNOMED CT |
| Encounter | `class` | `v3-ActCode` (AMB/EMER/IMP/HH/VR) — **not** a CodeableConcept, a bare Coding |
| Condition | `code` | SNOMED CT (259/259) |
| MedicationRequest | `medicationCodeableConcept` | RxNorm |
| Observation | `code` | LOINC (2942/2942) |
| Observation | `valueCodeableConcept` | SNOMED CT (511), LOINC (27) |

Clean single-system-per-domain: SNOMED for conditions/procedures, LOINC for observations,
RxNorm for drugs, CVX for immunisations. Real EHR data is never this tidy — worth stating plainly
in the README, because it means our mapping-coverage figure is an **optimistic upper bound**.

### Surprise 2 — references use TWO formats, not one

CLAUDE.md warned that Synthea writes `urn:uuid:xxxx` rather than `Patient/xxxx`. Confirmed — but
that is only true for **patient-scoped clinical links**. Provider/org/location links use a third form
the brief did not mention: a **conditional reference by business identifier**.

```
subject            -> "urn:uuid:ba419d35-0dfe-8af7-347c-eebf02485a56"
encounter          -> "urn:uuid:..."
serviceProvider    -> "Organization?identifier=https://github.com/synthetichealth/synthea|4705a8fd-..."
participant.individual -> "Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|9999951590"
location[].location    -> "Location?identifier=https://github.com/synthetichealth/synthea|373e6267-..."
```

Every `Encounter` carries all four. `ExplanationOfBenefit` additionally uses `#referral`, an internal
fragment reference into its own `contained[]` array.

*Consequence:* joining Encounter to Organization/Practitioner is **not** a UUID lookup. It requires
splitting the string on `|` and matching the token against the target's `identifier[].value` in the
`hospitalInformation`/`practitionerInformation` bundles. This affects `visit_occurrence.care_site_id`
and `provider_id`. Decision deferred to Step 5 — if we do not resolve these, both columns are NULL
and that must be reported as loss, not left unmentioned.

### Which date field each resource uses — confirmed

| Resource | Field(s) | Coverage |
|---|---|---|
| Patient | `birthDate` (date only, no time) | 6/6 |
| Patient | `deceasedDateTime` | **1/6 — optional** |
| Encounter | `period.start`, `period.end` | 364/364 both |
| Condition | `onsetDateTime`, `recordedDate` | 259/259 |
| Condition | `abatementDateTime` | **193/259 (74.5%)** |
| MedicationRequest | `authoredOn` | 220/220 |
| Observation | `effectiveDateTime`, `issued` | 2936/2936 |

All as CLAUDE.md predicted. Note Condition has **two** start-ish dates: `onsetDateTime` (clinical
onset) and `recordedDate` (when entered). OMOP `condition_start_date` means onset — using
`recordedDate` would be wrong, and in Synthea they are often identical, which means the bug would
not show up in testing. Flagged.

MedicationRequest has **no end date at all** — only `authoredOn`. OMOP `drug_exposure` requires
`drug_exposure_end_date` (NOT NULL). We will have to derive it or default it, and either choice is a
documented assumption, not a fact from the source.

### Surprise 3 — every timestamp carries the *generating machine's* timezone

```
TIMEZONE OFFSETS across all datetimes:  +05:30 -> 4371    +06:30 -> 4
```

The patients live in Massachusetts. The offsets are **Asia/Kolkata** — the timezone of the machine
that ran Synthea, not the patients'. Example: `deceasedDateTime: 2025-02-08T13:35:27+05:30`.

The 4 records at `+06:30` are not corruption: India observed UTC+6:30 during 1942–1945 ("Indian War
Time"), and our oldest patient was born in 1925, so a handful of her early records land in that
window and pick up the historical offset from the tz database.

*Consequence — this is the off-by-one-day trap, made concrete.* OMOP splits every event into
`_date` and `_datetime`. If we truncate the raw string (`substr(x,1,10)`) we get the Kolkata calendar
date. If we convert to America/New_York first, events between 00:00 and 10:30 IST move to the
**previous day**. The two approaches disagree on a real fraction of rows, and the disagreement is
invisible unless you look for it. Decision required in Step 5; whichever we pick gets stated in the
README, and I intend to **quantify how many rows shift** rather than assert one is correct.

### How Observation values vary

| Variant | n | % |
|---|---|---|
| `valueQuantity` | 2239 | 76.3% |
| `valueCodeableConcept` | 538 | 18.3% |
| **no `value[x]` at all** | **158** | **5.4%** |
| `valueString` | 1 | 0.0% |

A parser reading only `valueQuantity` silently drops **23.7%** of observations.

The 158 with no value are not empty — they carry `component[]` instead:

- 86 × "Blood pressure panel with all children optional" — 2 components (systolic, diastolic)
- 72 × "PRAPARE" social-determinants survey — 21 components each

So blood pressure, one of the most-used variables in clinical research, has **no scalar value** and is
invisible to a naive parser. In OMOP the panel must become two `measurement` rows, one per component.
This is bucket-2 material ("structured but not computable") if we do not handle components, and it is
the clearest example in the whole dataset of why this project's question matters.

By category: `laboratory` 1939, `vital-signs` 611, `survey` 270, `social-history` 89, `procedure` 17,
`imaging` 6, `therapy` 3, `exam` 1. Only lab + vitals are a natural fit for OMOP `measurement`;
survey and social-history belong in `observation`, which is **out of scope**. That is a deliberate,
quantified exclusion (359 rows, 12.2%) to record, not to quietly drop.

All `valueQuantity` units are UCUM (`http://unitsofmeasure.org`) — mg/dL, mmol/L, /min, %, kg, cm.
Good news for `unit_source_value`; still needs mapping to OMOP unit concepts.

### Surprise 4 — 20% of MedicationRequests hide the drug behind a reference

| medication[x] form | n | % |
|---|---|---|
| `medicationCodeableConcept` (RxNorm inline) | 176 | 80.0% |
| `medicationReference` (→ contained `Medication`) | 44 | 20.0% |

The 44 `Medication` resources in the bundles exist precisely to serve these. A `drug_exposure`
mapping that reads only `medicationCodeableConcept` loses **one drug exposure in five** — and loses
them non-randomly, since Synthea uses the reference form for specific administration types.
Must resolve `medicationReference` → `Medication.code` (RxNorm).

### What's optional (field presence across 6 patients)

Patient always has: `address`, `birthDate`, `communication`, `extension`, `gender`, `identifier`,
`maritalStatus`, `multipleBirthBoolean`, `name`, `telecom`, `text`.
Optional: **`deceasedDateTime` 1/6**.

Race and ethnicity are **not** first-class fields — they are US Core extensions:
`extension[url=.../us-core-race].extension[url=ombCategory].valueCoding.code` (e.g. `2106-3` = White).
Both carry an `ombCategory` coding plus a `text` string. Only the 5 OMB categories appear in this
sample; US Core also permits a `detailed` sub-extension, absent here — so **granularity loss to OMOP
is small for this dataset but would be large for real US Core data**. Worth saying, since it stops the
report from over-claiming.

Other notable optionality: Encounter `reasonCode` 238/364 (65.4%); Condition `abatementDateTime`
193/259; MedicationRequest `dosageInstruction` 118/220 (53.6%), `reasonReference` 191/220.

Condition categorical values — **all 259 are `encounter-diagnosis`**, `verificationStatus` all
`confirmed`, `clinicalStatus` 193 resolved / 66 active. So the diagnosis-vs-problem-list-vs-symptom
ambiguity CLAUDE.md flagged **does not bite in this sample** — there are no problem-list entries.
That simplifies the mapping but narrows the finding: I should say the ambiguity is untested here
rather than claim we handled it.

Encounter `class`: AMB 334, EMER 14, IMP 11, HH 3, VR 2. Maps to OMOP visit concepts, but note
IMP (inpatient) is only 11 rows — inpatient logic will be barely exercised at this sample size.

MedicationRequest `status`: completed 211, active 9. `intent`: all 220 `order`.

---

### Open decisions carried into Step 5

1. Timezone: truncate raw (+05:30) or convert to America/New_York? Quantify the row-level disagreement.
2. Observation `component[]`: expand blood-pressure panels into 2 measurement rows, or reject?
3. `medicationReference`: resolve via contained `Medication`, or reject 20% of drug exposures?
4. Conditional references (`Organization?identifier=...|`): resolve care_site/provider, or NULL + report?
5. `drug_exposure_end_date` has no source field — derive, default, or reject?
6. Survey + social-history Observations (359 rows): out of scope by design — record as excluded, not lost.
