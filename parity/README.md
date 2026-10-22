# Parity plan

Central reference for tracking **Oracle** and **MySQL** compatibility of the
`dart_db_server` engine. This folder is the jumping-off point: the living plan
docs live under [`../doc/`](../doc), and this folder adds a **test-data catalog**
(what to load, where to download it) plus a local drop directory for the
datasets themselves.

## Contents

| File | Purpose |
| --- | --- |
| [`parity-report.md`](parity-report.md) | Latest results of loading the sample schemas through the engine (coverage %, rejections, prioritized gaps). Regenerated from [`../test/parity/`](../test/parity). |
| [`test-data.md`](test-data.md) | Catalog of standard Oracle/MySQL sample schemas and benchmark datasets, with official download locations and load notes. |
| [`datasets/`](datasets) | Local drop directory for downloaded datasets (git-ignored; see note below). |

## Source-of-truth plan docs (in `../doc/`)

- [sql-dialect-parity.md](../doc/sql-dialect-parity.md) — snapshot of **what
  works today** across wire protocol and SQL surface for both dialects.
- [parity-roadmap.md](../doc/parity-roadmap.md) — ordered plan for **what's
  left** (gap inventory G1–G11, effort/risk, acceptance criteria).
- [oracle-wire-protocol-plan.md](../doc/oracle-wire-protocol-plan.md) — Oracle
  TTC/TNS front-end phases and status.
- [oracle-native-thick-client-auth.md](../doc/oracle-native-thick-client-auth.md)
  — native OCI/OCCI client auth work.
- [sql-compat matrix & idioms](../doc/sql-dialect-parity.md#3-oracle-compatibility)
  — Oracle idioms, scalar functions, and wire type codecs.

## How to use this folder

1. Pick a parity gap from [parity-roadmap.md](../doc/parity-roadmap.md).
2. Load a relevant dataset from [test-data.md](test-data.md) into
   `dart_db_server` (over the Oracle or MySQL wire) **and** into the real engine
   as an oracle.
3. Run the same queries against both; diff the results.
4. Record the outcome against the gap's acceptance criteria.

## Datasets directory

`datasets/` is where downloaded sample/benchmark data is expected to live
locally. The data itself is **not** committed (it is large and externally
licensed). Add an ignore rule if not already covered:

```gitignore
parity/datasets/**
!parity/datasets/.gitkeep
```
