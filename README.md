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

## Requirements

**You'll need to compile Ruby master (≥ 2026-07, reported as `4.1.0dev`).**
On any released Ruby the Ractor server crashes under load.
Ruby master is needed because under real concurrency, worker Ractors calling `super` with keyword arguments trip a CRuby
VM data race on the global call-info table (`vm->ci_table`) and crash with
`SIGBUS` — **fixed only in Ruby master**.

## Installation

1. `git clone --branch ec-ractor-safe https://github.com/Shopify/writebook.git`
2. `cd writebook`
3. `ruby -v` Cconfirm you are on Ruby master (4.1.0dev)
4. `bundle install`
5. `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile`

## Benchmarks

This repository contain multiple benchmarks described below:

### Boot & latency benchmark

`script/benchmark.sh`.

This benchmark measure boot time on a baseline (Vanilla writebook with Ruby 4.1.0dev) against
ractorized Writebook (the application itself contain ractor safety fixes, unsafe gems are patched and Rails
is point at a fork with no Ractor shareability issues).

The benchmark also measure the time spent on Ractor main (Work is dispatched to the main Ractor when it's not possible
to execute it in the worker Ractor, either due to connection pool owned by the Main ractor or because gems with C extensions
aren't Ractor safe).

### Memory-saturation benchmark

`script/memory_saturation.sh`

This benchmark meaures memory usage — a Puma **cluster** versus a single-process **Ractor pool**
while the two serve the same concurrent load.
The endpoint used is the `/up` (it just pings the application), no computation, no DB queries and no work is dispatched
the Main ractor.

The benchmark also measure throughput and latency with a **3 way comparison**. Clustered Puma with N workers VS one process
with N Ractors, **with and without YJIT** enabled. Turning **off** YJIT drastically **increase** throuput.
The web worker used for benchmarking Ractors is [kino](https://github.com/yaroslav/kino).

### YJIT

In order to confirm that turning ON YJIT degrades performance there is a few self isolated scripts that confirm this problem.

1. Serving requests in a simple Rack application that returns a 200

**Throughput isn't affected and scales as we increase the number of ractors**.

```
for n in 1 8; do N=$n ruby script/ractor_trivial_bench.rb; done;
for n in 1 8; do N=$n YJIT=1 ruby script/ractor_trivial_bench.rb; done;
```

2. Serving requests by the Rails application with a dummy rack env.

**Throughput is affected when the number of Ractor increases**.

```
for n in 1 8; do N=$n ruby script/ractor_appcall_bench.rb; done;
for n in 1 8; do N=$n NO_YJIT=1 ruby script/ractor_appcall_bench.rb; done;
```

You can also set the `PROFILE=1` environment variable and the script will profile the whole process during the run, and write
the `tmp/ractor_appcall_sample.txt` sample.

You can also set the `STATS=1` environment variable and the script will enable YJIT runtime stats.

3. Simple self contained Ruby script that shows the YJIT degradation (no Rails application)

```
$ for wl in escape noescape; do for n in 1 8; do WORKLOAD=$wl YJIT=1 N=$n ruby script/ractor_escape_bench.rb; done; done
```

Multi-Ractor + YJIT throughput collapse is triggered by materializing a frame's environment (creating a closure/binding that captures locals — "EP escape").
