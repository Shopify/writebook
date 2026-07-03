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

## Running the benchmark

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
| `N` | `150` | requests per GET endpoint (LATENCY phase) |
| `WARMUP` | `40` | warmup requests per endpoint |
| `N_POST` | `15` | `POST /first_run` samples |
| `POST_WARMUP` | `3` | warmup POSTs |
| `PORT` | `3998` | port the benchmark server listens on |
| `SKIP_BOOT` / `SKIP_LATENCY` | – | set to `1` to skip a phase |
