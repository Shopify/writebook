# Writebook — Ractor experiment

This is a fork of [Writebook](https://github.com/basecamp/writebook) used as an
experiment: **can an existing, real-world Rails application serve HTTP requests
from inside a non-main Ractor?**

Each request runs in its own worker Ractor while the application graph is frozen
and shared. Work that can't (yet) run off the main Ractor — database access,
image processing, Markdown/HTML rendering — is dispatched back to the main
Ractor. Most of the changes that make this possible live in a companion **Rails
fork** ([`Shopify/rails`, branch `writebook-ractorize`](https://github.com/Shopify/rails/tree/writebook-ractorize)),
which the `Gemfile` points at; the app itself carries only a thin Rack bridge
(`config/initializers/ractor_patches.rb`), a handful of gem shims
(`config/patches/*.rb`), and the benchmark scripts.

The goal at this stage is **not** to show that Ractor serving is faster, but to
show it works and has **no meaningful negative performance impact** so far.

## How it works, briefly

- `config.ru` freezes and shares the whole application (`ractorize!`) and serves
  every request through `RactorPatches::Bridge`, which spawns a worker Ractor per
  request. Setting `RACTOR_MODE=0` disables this and serves the app normally, on
  the main Ractor — used as the benchmark baseline.
- DB / image / render work is sent to the main Ractor via `Ractor::Dispatch`.
- With `RACTOR_METRICS=1`, each response carries `x-rz-*` timing headers used by
  the benchmark.

## Ruby version

**Both benchmarks require Ruby master** (≥ 2026-07, reported as `4.1.0dev`), which
is the committed `.ruby-version`. Ruby master is needed because under real
concurrency, worker Ractors calling `super` with keyword arguments trip a CRuby
VM data race on the global call-info table (`vm->ci_table`) and crash with
`SIGBUS` — **fixed only in Ruby master**. On any released Ruby the Ractor server
crashes under load; `script/memory_saturation.sh` detects this, prints
`*** CRASHED under load ***`, and exits non-zero rather than reporting bogus
numbers.

Build/install a Ruby master (e.g. with `ruby-build`, or from a source checkout)
and select it before running either benchmark.

## Boot & latency benchmark

```sh
git clone --branch ec-ractor-safe https://github.com/Shopify/writebook.git
cd writebook

ruby -v          # confirm you are on Ruby master (4.1.0dev)
bundle install
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile

script/benchmark.sh
```

### What it reports

`script/benchmark.sh` runs two phases and prints both:

1. **BOOT** — boot time and memory of the **`ec-baseline` branch** (vanilla
   Writebook, no Ractor) vs **HEAD + `ractorize!`** — the true one-time cost of
   the experiment. Worktrees the baseline branch and boots each side `BOOT_RUNS`
   times (override with `BASELINE_BRANCH`).
2. **LATENCY** — concurrency-1 latency (p50/p90/p99) of the same build served
   with Ractors vs without (`RACTOR_MODE=0`), across a gradient of endpoints:
   `/up` (no DB), `GET /first_run` (render), `POST /first_run` (the write path),
   and the authenticated `/` (real read path). Ractor rows also show the per-
   request main-Ractor time and dispatch count.

### Configuration

All optional, via environment variables:

| var | default | meaning |
|-----|---------|---------|
| `BOOT_RUNS` | `5` | boots per configuration (BOOT phase) |
| `N` | `2000` | requests per GET endpoint (LATENCY phase; high so p99 is stable) |
| `WARMUP` | `40` | warmup requests per endpoint |
| `N_POST` | `15` | `POST /first_run` samples |
| `POST_WARMUP` | `3` | warmup POSTs |
| `PORT` | `3998` | port the benchmark server listens on |
| `SKIP_BOOT` / `SKIP_LATENCY` | – | set to `1` to skip a phase |

## Memory-saturation benchmark

This is the headline comparison: the memory needed to **saturate N cores** two
ways — a Puma **cluster** running the **`ec-baseline` branch** (vanilla Writebook,
N worker processes — the traditional way to use N cores on CRuby) versus a
single-process **Ractor pool** (this build, N worker Ractors sharing one frozen
heap) — while both serve the same concurrent load. It measures each config for
**two endpoints**: `/up` (healthcheck, no DB — shows pure parallel throughput) and
the authenticated `/` (DB + render — the real read path). The script manages the
baseline worktree itself. Like the boot/latency benchmark it runs on Ruby master
(see [Ruby version](#ruby-version)):

```sh
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile

script/memory_saturation.sh 1 2 4 8   # the N values to sweep (default: 1 2 4 8)
```

It prints one table per endpoint; for each N: process count, peak RSS under load,
throughput (rps), memory per unit throughput (MB/rps), and the memory gain
(cluster RSS / pool RSS). The headline is the **scaling**: Puma RSS grows
~linearly (each worker is a full app copy) while the Ractor pool stays flat
(shared heap), so the gain compounds with core count — on both endpoints.

On `/` (DB-bound) the pool's throughput is capped by the single main-dispatch
thread (all DB funnels through one executor); on `/up` (no DB) it runs fully
parallel. A per-Ractor DB connection would let `/` scale like the cluster too,
while keeping the flat memory curve. (Runs that crash under load are flagged and
fail the benchmark rather than reporting bogus numbers.)

| var | default | meaning |
|-----|---------|---------|
| _(positional args)_ | `1 2 4 8` | the N values (cores / workers) to sweep |
| `LOAD_SECS` | `10` | seconds of sustained load per measurement |
| `PORT` | `3996` | port the benchmark server listens on |
