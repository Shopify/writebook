#!/usr/bin/env bash
#
# Ractor experiment benchmark -- one command, all results.
#
#   script/benchmark.sh
#
# Runs two phases and prints both reports:
#
#   1. BOOT      boot time + RSS of the ec-baseline branch (vanilla Writebook, no
#                Ractor) vs HEAD + ractorize! -- the true cost of the experiment.
#                Worktrees the baseline branch and boots each BOOT_RUNS times.
#   2. LATENCY   concurrency-1 latency of the SAME build served with Ractors vs
#                without (RACTOR_MODE=0), across /up, GET/POST /first_run, and
#                authenticated / -- with the worker/main/dispatch breakdown.
#
# Config via env (all optional):
#   BOOT_RUNS=5  N=150  WARMUP=40  N_POST=15  POST_WARMUP=3  PORT=3998
#   BASELINE_BRANCH=ec-baseline     # vanilla baseline for the BOOT phase
#   SKIP_BOOT=1 / SKIP_LATENCY=1
#
# Requires Ruby master (4.1.0dev) active -- same as the experiment.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

BOOT_RUNS="${BOOT_RUNS:-5}"
N="${N:-2000}"
WARMUP="${WARMUP:-40}"
N_POST="${N_POST:-15}"
POST_WARMUP="${POST_WARMUP:-3}"
PORT="${PORT:-3998}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret123456}"

rv="$(ruby -e 'print RUBY_VERSION')"
case "$rv" in
  4.1.*) ;;
  *) echo "WARNING: Ruby $rv is active but the experiment targets Ruby master (4.1.0dev)." >&2 ;;
esac

# --- shared cleanup (worktree + server + temp files) ---
WT="" ; WT_PARENT="" ; SERVER_PID="" ; TMPFILES=()
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
  [ -n "$WT" ] && git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  [ -n "$WT_PARENT" ] && rm -rf "$WT_PARENT"
  for f in "${TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done
}
trap cleanup EXIT

# ===========================================================================
# PHASE 1 -- BOOT
# ===========================================================================
phase_boot() {
  echo "########## PHASE 1: BOOT ##########" >&2
  local ref="${BASELINE_BRANCH:-ec-baseline}"
  git rev-parse --verify "$ref" >/dev/null 2>&1 || ref="origin/${BASELINE_BRANCH:-ec-baseline}" # fresh clone: use remote-tracking ref
  git rev-parse --verify "$ref" >/dev/null 2>&1 || { echo "baseline branch not found (need '${BASELINE_BRANCH:-ec-baseline}' locally or on origin)." >&2; return 1; }
  echo "Baseline:   $(git log -1 --format='%h %s' "$ref")" >&2
  echo "Experiment: $(git log -1 --format='%h %s' HEAD)" >&2

  WT_PARENT="$(mktemp -d)"; WT="$WT_PARENT/wb-baseline"
  echo "== Creating baseline worktree ($ref) ==" >&2
  git worktree add -f "$WT" "$ref" >/dev/null 2>&1
  cp "$APP_DIR/script/boot_delta.rb" "$WT/script/boot_delta.rb"  # baseline lacks it

  echo "== bundle install (baseline) ==" >&2
  if ! ( cd "$WT" && bundle install ) >/dev/null 2>&1; then
    echo "baseline bundle install failed:" >&2; ( cd "$WT" && bundle install ) 2>&1 | tail -15; return 1
  fi

  local base_out exp_out; base_out="$(mktemp)"; exp_out="$(mktemp)"; TMPFILES+=("$base_out" "$exp_out")
  local dir label out i line rest
  for pair in "$WT:baseline:$base_out" "$APP_DIR:experiment:$exp_out"; do
    dir="${pair%%:*}"; rest="${pair#*:}"; label="${rest%%:*}"; out="${rest#*:}"; : > "$out"
    echo "== Booting $label x$BOOT_RUNS ==" >&2
    for i in $(seq 1 "$BOOT_RUNS"); do
      if line="$(cd "$dir" && ruby script/boot_delta.rb 2>/dev/null | grep '^BOOTDELTA')"; then echo "$line" >> "$out"; fi
    done
  done
  echo >&2

  # baseline (ec-baseline: vanilla Rails, no ractorize!) reports base boot only;
  # experiment (HEAD) reports base boot + the ractorize! cost. Delta = the whole
  # cost of the experiment vs vanilla Writebook, on the same Ruby.
  ruby - "$base_out" "$exp_out" <<'RUBY'
base = File.readlines(ARGV[0]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
exp  = File.readlines(ARGV[1]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
abort "no successful boot runs" if base.empty? || exp.empty?
def med(xs) = (s = xs.sort; s.size.odd? ? s[s.size/2] : (s[s.size/2-1]+s[s.size/2])/2.0)
def col(rows, i) = rows.map { |r| r[i] }
def b(s) = $stdout.tty? ? "\e[1m#{s}\e[0m" : s.to_s
def c(s, code) = $stdout.tty? ? "\e[#{code}m#{s}\e[0m" : s.to_s
WARMING = 33; SHAREABLE = 32; ONFREEZE = 36 # yellow / green / teal
b_boot = med(col(base,0)); b_rss = med(col(base,6))
e_full = med(exp.map { |r| r[0]+r[2] }); e_rss2 = med(col(exp,7))
e_bf = med(col(exp,3)); e_gf = med(col(exp,4)); e_on = med(col(exp,5))
delta = e_full - b_boot
n = [base.size, exp.size].min
printf("Boot time: baseline (main, no Ractor) vs experiment + ractorize! (median of %d boots/side, production)\n\n", n)
printf("%-30s %10s %10s\n", "", "boot ms", "RSS MB")
printf("%-30s %10s %10s\n", "-"*30, "-"*10, "-"*10)
printf("%-30s %10.1f %10.1f\n", "before (main, no Ractor)", b_boot, b_rss)
printf("%-30s %10.1f %10.1f\n", "after  (+ ractorize!)", e_full, e_rss2)
puts
printf("Cost of the experiment: %s, RSS %+.1f MB\n",
       b(sprintf("%+.1f ms (%+.1f%%)", delta, delta / b_boot * 100)), e_rss2 - b_rss)
printf("  of which one-time ractorize!:  %s %.1f  /  %s %.1f  /  %s %.1f ms\n",
       c("warming", WARMING), e_bf, c("make_shareable", SHAREABLE), e_gf, c("on_freeze", ONFREEZE), e_on)
puts
puts "  #{c("warming", WARMING)}#{" " * 7} force lazily-memoized state (reflections, schema, url helpers) up-front so it can be frozen"
puts "  #{c("make_shareable", SHAREABLE)} deep-freeze the whole application object graph so Ractors can share it"
puts "  #{c("on_freeze", ONFREEZE)}#{" " * 5} freeze gem/framework state outside the graph + recompile callback chains as shareable procs"
RUBY

  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT_PARENT"; WT=""; WT_PARENT=""
}

# ===========================================================================
# PHASE 2 -- LATENCY
# ===========================================================================
phase_latency() {
  echo >&2
  echo "########## PHASE 2: LATENCY (concurrency 1) ##########" >&2
  export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1

  local out; out="$(mktemp)"; TMPFILES+=("$out")

  reset_db() {
    DISABLE_DATABASE_ENVIRONMENT_CHECK=1 SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production \
      bin/rails db:reset >/dev/null 2>&1 || { echo "db reset failed" >&2; return 1; }
  }
  wait_ready() {
    for _ in $(seq 1 80); do
      curl -sf -o /dev/null "http://127.0.0.1:$PORT/up" -H "User-Agent: probe" && return 0
      sleep 0.5
    done
    return 1
  }
  run_mode() { # $1 = label, $2... = extra env
    local label="$1"; shift
    reset_db
    rm -f /tmp/bench_server.log
    ( env "$@" bin/rails server -p "$PORT" -b 127.0.0.1 >/tmp/bench_server.log 2>&1 ) &
    SERVER_PID=$!
    disown "$SERVER_PID" 2>/dev/null || true  # stop bash printing "Terminated" when we kill it
    if ! wait_ready; then echo "[$label] server did not become ready:" >&2; tail -15 /tmp/bench_server.log >&2; return 1; fi
    echo "== [$label] probing (N=$N warmup=$WARMUP N_POST=$N_POST) ==" >&2
    MODE="$label" PORT="$PORT" N="$N" WARMUP="$WARMUP" N_POST="$N_POST" POST_WARMUP="$POST_WARMUP" \
      ruby script/latency_probe.rb 2>/dev/null >> "$out"
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
    SERVER_PID=""
    sleep 1
  }

  # Ractor mode renders 500s without a Propshaft manifest (the digest cache can't
  # be populated inside a frozen worker Ractor), so ensure assets are precompiled.
  if [ ! -f public/assets/.manifest.json ]; then
    echo "== precompiling assets (required for Ractor mode) ==" >&2
    bin/rails assets:precompile >/dev/null 2>&1 || { echo "assets:precompile failed" >&2; return 1; }
  fi

  run_mode base   RACTOR_MODE=0
  run_mode ractor RACTOR_METRICS=1
  echo >&2

  ruby - "$out" <<'RUBY'
rows = File.readlines(ARGV[0]).map { |l| l.strip.split(",") }.select { |r| r[0] == "LAT" }
by = Hash.new { |h, k| h[k] = {} }
rows.each { |r| by[r[2]][r[1]] = r }
order = ["/up", "/first_run", "POST /first_run", "/"]
def bold(s) = $stdout.tty? ? "\e[1m#{s}\e[0m" : s.to_s
def c(s, code) = $stdout.tty? ? "\e[#{code}m#{s}\e[0m" : s.to_s
puts "Concurrency-1 latency: base (no Ractor) vs ractor  [client-side ms]"
puts
printf("%-16s %-7s %8s %8s %s %s %8s %9s\n",
       "endpoint", "mode", "p50", "p99",
       c(sprintf("%8s", "db"), 32), c(sprintf("%8s", "other"), 36), "worker", "ok")
printf("%s\n", "-"*80)
failed = false
order.each do |ep|
  next unless by.key?(ep)
  %w[base ractor].each do |m|
    r = by[ep][m] or next
    db  = m == "ractor" ? r[10] : "-"
    oth = m == "ractor" ? r[11] : "-"
    wrk = m == "ractor" ? r[12] : "-"
    okn, tot = r[3].split("/").map(&:to_i)
    failed = true if okn < tot
    okf = okn < tot ? c(sprintf("%9s", r[3]), 31) : sprintf("%9s", r[3]) # red when some requests failed
    printf("%-16s %-7s %s %8s %8s %8s %8s %s\n", ep, m, bold(sprintf("%8s", r[4])), r[6], db, oth, wrk, okf)
  end
  b = by[ep]["base"]; x = by[ep]["ractor"]
  if b && x && b[4].to_f > 0
    d = x[4].to_f - b[4].to_f
    printf("%-16s %-7s p50 %s   [server wall %s ms, app %s ms]\n",
           "", "delta", bold(sprintf("%+.2f ms", d)), x[8], x[9])
  end
  puts
end
puts "  #{c("db", 32)}#{" " * 4} ms on the main Ractor: DB / connection calls"
puts "  #{c("other", 36)}#{" " * 1} ms on the main Ractor: Markdown rendering (Redcarpet C ext), HTML sanitize (Loofah unsafe), image analysis (vips unsafe)"
puts "  worker ms running the app in the worker Ractor"
puts "  ok     successful responses / total (2xx for GETs, 3xx for POST /first_run)"
if failed
  puts
  puts "!!! Some requests FAILED (ok < total above) -- these latency numbers are NOT"
  puts "!!! valid. Most often Ractor mode returns 500s without precompiled assets:"
  puts "!!!   RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile"
  exit 1
end
RUBY
}

[ "${SKIP_BOOT:-}"    = "1" ] || phase_boot
[ "${SKIP_LATENCY:-}" = "1" ] || phase_latency
