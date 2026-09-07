# CLAUDE.md — FHIR → OMOP Data Quality Project

Place this at the repo root. Read it fully before starting.

---

## What we're building

A pipeline that maps synthetic patient records from **FHIR** into the **OMOP Common Data Model**, then runs a data quality assessment in SQL to answer one question:

> **What proportion of clinical data survives the mapping, and what exactly is lost?**

The pipeline is not the deliverable. The **quantified answer to that question** is. Everyone assumes interoperability standards are lossless; they aren't. Naming which clinical concepts fall through is the finding.

**Decision it supports:** whether an OMOP-derived dataset is fit for a specific research question, or whether the mapping has quietly removed the thing you wanted to study.

---

## Who I am and how to work with me

Two years as a clinical data manager — I mapped messy source data into CDISC standards (CDASH, SDTM) daily, ran UAT on EDC systems, and validated 100+ edit checks. Fluent in Python. I know what a data quality check is. **I am new to SQL.**

So:

1. **Explain each query before writing it.** What it does and why that approach. I will be interviewed on this code and I cannot say "Claude wrote it."
2. **Teach the SQL idiom.** When you use a CTE, a window function, a `LEFT JOIN` where I'd expect an inner join, or `COALESCE`, say in one line what it does and why it's right here.
3. **Readable over clever.** CTEs, not nested subqueries. Named steps, not one giant statement.
4. **Push back.** If I propose a mapping that loses information silently, say so.

Working today in one long session. Environment is already set up: `.venv` with duckdb and pandas, folders created, `.gitignore` correct.

---

## Language rule

**This is a SQL project.** Python is used only to flatten FHIR JSON into staging tables. Every transformation from staging onward must be SQL. Do not solve a mapping problem in pandas because it's easier — that defeats the purpose of the repo.

---

## Step 1 — Generate and inspect (do not skip the inspection)

I'll download `synthea-with-dependencies.jar` to the repo root myself.

Run:
```
java -jar synthea-with-dependencies.jar -p 5 -s 42
```

Five patients only. Output lands in `output/fhir/`.

**Then, before writing any parser**, write a small exploration script and walk me through the structure. Report on each of these and record them in `NOTES.md`:

- **Bundle shape** — top-level keys, the `entry` array, how each entry wraps a `resource` with its own `resourceType`. Count resources by type.
- **Where clinical codes live** — e.g. `code.coding[0].code` with a `system` URL. Note that `coding` is an array and may hold more than one entry. Which system does Synthea use for each resource type?
- **How references are written** — Synthea uses `urn:uuid:xxxx`, **not** `Patient/xxxx`. If the parser assumes the second form every join silently returns nothing. This is the most common way this project breaks. Confirm the actual format.
- **Which date field each resource uses** — Condition `onsetDateTime`, Encounter `period.start`/`period.end`, Observation `effectiveDateTime`. Confirm and note.
- **How Observation values vary** — `valueQuantity`, `valueCodeableConcept`, `valueString`. Count how many of each. A parser assuming `valueQuantity` drops a large share of rows.
- **What's optional** — compare the same resource type across two patients. Fields present in one and absent in the other must be handled as missing.

Show me the findings and wait for my go-ahead before building the parser.

Then regenerate at full size: `java -jar synthea-with-dependencies.jar -p 1000 -s 42`

---

## Step 2 — Stage

Python flattens FHIR bundles into DuckDB staging tables, one per resource type. **Faithful flat copy — no transformation.**

---

## Step 3 — Write the quality checks BEFORE any mapping

Create `eval/quality_checks.md` listing every check with its threshold, then commit it **before** a single line of mapping SQL exists. The commit timestamp is the point: it proves the standard was set before the results were seen.

Use the **OHDSI Data Quality Dashboard** categories. Do not invent alternatives:

- **Conformance** — types correct, concept IDs valid, required fields present, foreign keys resolve
- **Completeness** — missingness by field and by domain
- **Plausibility** — age < 120; no death before birth; no drug exposure or condition after death; visit end not before visit start; lab values within physiological range

---

## Step 4 — Load OMOP CDM v5.4 DDL

So the target tables exist and are correctly typed.

---

## Step 5 — Map, in SQL

One `.sql` file per target table, in dependency order. Each file opens with a comment block: what it maps, what it assumes, what it drops.

| FHIR resource | → OMOP table |
|---|---|
| Patient | `person` |
| Encounter | `visit_occurrence` |
| Condition | `condition_occurrence` |
| MedicationRequest | `drug_exposure` |
| Observation | `measurement` |

`person` first — every clinical table has a foreign key to it.

**Decisions to make and defend:**
- Gender, race, ethnicity use different code systems in each standard. Where does granularity get lost?
- FHIR carries timezones; OMOP splits date and datetime. What happens at boundaries?
- Source code → OMOP `concept_id`. What proportion maps? Keep unmapped codes, don't discard.
- Populate `*_source_value` columns. That's OMOP's own provenance mechanism.

---

## Step 6 — Build `etl_rejects`

Every unmappable row, with source row, target table, and reason code. **Row counts must reconcile: source = mapped + rejected.**

This table is the most interesting artifact in the repo.

---

## Step 7 — Run the checks, then the loss analysis

Every check from `quality_checks.md` as SQL, one query per check, returning: check name, rows evaluated, rows failed, pass/fail against the day-1 threshold.

Then per domain: rows in source, rows mapped, rows rejected, top reasons. **Which clinical concepts fell through, and would their absence change a research conclusion?**

Track three buckets separately, never collapsing the last two:
1. Structured and computable
2. Structured but not computable
3. Could not be structured at all

---

## Scope — do not exceed

Five OMOP tables, five FHIR resources, as above. If I ask for more mid-session, remind me the scope is deliberate and ask what I want to trade out.

**Out of scope, state in README:** the full OMOP CDM (~40 tables), full provenance round-tripping, real patient data, production-grade ETL.

---

## Vocabulary

The full Athena download is several gigabytes. **Not required.** Hand-map the most frequent source codes per domain and report coverage honestly. The long tail of unmapped codes *is* the finding. Do not pretend to full coverage.

---

## Hard rules

- **Never silently drop a row.** Everything unmappable goes to `etl_rejects` with a reason.
- **Never fabricate a concept mapping.** No OMOP concept → `concept_id` 0, recorded as unmapped. Never guess a plausible-looking ID.
- **Always populate `*_source_value`.** Losing the original code is a real failure.
- **Never report a check without the denominator.** "142 failures" is meaningless; "142 of 8,904 (1.6%)" is a result.
- **Do not tune the mapping to make the report look good.** A high rejection rate, honestly explained, is the point.
- Fixed seed, recorded in the README.
- **Never commit anything under `data/` or `output/`.** Show me what's staged before every commit.
- Commit after each numbered step, with messages describing the **decision**, not the file. Good: *"Map person table; keep unmapped race codes rather than defaulting to Unknown."* Bad: *"added mapping files."*
- Maintain `NOTES.md` throughout — what I decided, what I rejected, what surprised me. This becomes README sections 4 and 6.

---

## Known traps

- **`urn:uuid:` references** — see Step 1.
- **Datetime boundaries** — off-by-one-day errors are the classic ETL bug here.
- **Synthea Observations mix vital signs, lab results and survey responses.** They don't all belong in `measurement`. Decide what to do with the rest and say so.
- **A FHIR Condition may be a diagnosis, a problem-list entry, or a symptom.** Not equivalent in OMOP. Note the ambiguity.
- **Gender/race/ethnicity mappings lose granularity.** Quantify it rather than glossing.
- **`git check-ignore -v <dir>/` with a trailing slash gives false positives on git 2.55.** Test an actual file path or use `git status --porcelain`.

---

## README structure (write last, in this order)

1. The problem — interoperability standards are assumed lossless; they aren't
2. The decision this supports
3. What it does — pipeline overview and the headline mapping-loss figure
4. What I chose not to build, and why
5. Quality framework — DQD categories, checks defined before mapping
6. **What was lost in mapping** — per domain, with reasons
7. What would be needed for real use — full vocabulary coverage, provenance, incremental loads, validation against a real source system
8. Run instructions — including the exact Synthea command and seed

Sections 4, 6 and 7 carry the weight. Do not compress them.

Add one line near the end: *Built with AI assistance; all design decisions, evaluation criteria and analysis are mine.*

---

## Tone

Plain and direct. A competent data engineer's working report, not marketing copy. Where the pipeline is weak, say it's weak and say why.
