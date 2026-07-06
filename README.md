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

Two benchmarks ship here, and they have **different Ruby requirements**:

- **`script/benchmark.sh`** (boot + concurrency-1 latency) runs on **Ruby 4.0.1**.
- **`script/memory_saturation.sh`** (memory vs. cores) requires **Ruby master**
  (≥ 2026-07, reported as `4.1.0dev`). Under real concurrency, worker Ractors
  calling `super` with keyword arguments trip a CRuby VM data race on the global
  call-info table (`vm->ci_table`) and crash with `SIGBUS`. It is **fixed only in
  Ruby master** — on 4.0.1 (and any released Ruby) the Ractor server crashes
  under the benchmark's own load. The script detects this, prints
  `*** CRASHED under load ***`, and exits non-zero rather than reporting bogus
  numbers, so you cannot accidentally benchmark a crashing server.

## Boot & latency benchmark (Ruby 4.0.1)

```sh
git clone --branch ec-ractor-safe https://github.com/Shopify/writebook.git
cd writebook

chruby 4.0.1
bundle install
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile

script/benchmark.sh
```

### What it reports

`script/benchmark.sh` runs two phases and prints both:

1. **BOOT** — boot time and memory for three configurations: the pre-Ractor
   `main` baseline (in a throwaway git worktree), the experiment without
   `ractorize!`, and the experiment with `ractorize!`. Shows the one-time cost
   the Ractor machinery adds at boot.
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

## Memory-saturation benchmark (Ruby master)

This is the headline comparison: the memory needed to **saturate N cores** two
ways — a Puma **cluster** (N worker processes, the traditional way to use N cores
on CRuby) versus a single-process **Ractor pool** (N worker Ractors sharing one
frozen heap) — while both serve the same concurrent authenticated `GET /` load.

This benchmark **requires Ruby master** (see [Ruby version](#ruby-version)).
Build/install it (e.g. with `ruby-build`, or from a source checkout), select it,
and point `.ruby-version` at it so Bundler accepts it:

```sh
ruby -v                              # confirm you are on master, e.g. 4.1.0dev
echo "4.1.0.dev" > .ruby-version      # match your build's reported version
bundle install                       # redcarpet 3.6.1 (TypedData) builds on 4.1
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile

script/memory_saturation.sh 1 2 4 8   # the N values to sweep (default: 1 2 4 8)
```

For each N it prints process count, peak RSS under load, throughput (rps), memory
per unit throughput (MB/rps), and the memory gain (cluster RSS / pool RSS). The
headline is the **scaling**: Puma RSS grows ~linearly (each worker is a full app
copy) while the Ractor pool stays flat (shared heap), so the gain compounds with
core count.

The pool's throughput is currently capped by the single main-dispatch thread
(all DB funnels through one executor); a per-Ractor DB connection would let it
scale like the cluster while keeping the flat memory curve.

| var | default | meaning |
|-----|---------|---------|
| _(positional args)_ | `1 2 4 8` | the N values (cores / workers) to sweep |
| `LOAD_SECS` | `10` | seconds of sustained load per measurement |
| `PORT` | `3996` | port the benchmark server listens on |
