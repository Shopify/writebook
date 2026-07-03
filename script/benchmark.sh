#!/usr/bin/env bash
#
# Ractor experiment benchmark -- one command, all results.
#
#   script/benchmark.sh
#
# Runs two phases and prints both reports:
#
#   1. BOOT      baseline (pre-Ractor "main" checkout) vs experiment base boot vs
#                experiment + ractorize!  (auto-detects the baseline commit,
#                creates a throwaway worktree, normalizes its cache store,
#                bundles it, and boots each side BOOT_RUNS times).
#   2. LATENCY   concurrency-1 latency of the SAME build served with Ractors vs
#                without (RACTOR_MODE=0), across /up, GET/POST /first_run, and
#                authenticated / -- with the worker/main/dispatch breakdown.
#
# Config via env (all optional):
#   BOOT_RUNS=5  N=150  WARMUP=40  N_POST=15  POST_WARMUP=3  PORT=3998
#   BASELINE_REF=<sha>      # override auto-detected pre-Ractor commit
#   SKIP_BOOT=1 / SKIP_LATENCY=1
#
# Requires Ruby 4.x active (chruby 4.0.1) -- same as the experiment.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

BOOT_RUNS="${BOOT_RUNS:-5}"
N="${N:-150}"
WARMUP="${WARMUP:-40}"
N_POST="${N_POST:-15}"
POST_WARMUP="${POST_WARMUP:-3}"
PORT="${PORT:-3998}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret123456}"

rv="$(ruby -e 'print RUBY_VERSION')"
case "$rv" in
  4.*) ;;
  *) echo "WARNING: Ruby $rv is active but the experiment needs Ruby 4.x (chruby 4.0.1)." >&2 ;;
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

  local ref
  ref="${BASELINE_REF:-}"
  if [ -z "$ref" ]; then
    local first_ractor
    first_ractor="$(git log --reverse --format=%H -- config/initializers/ractor_patches.rb | head -1)"
    [ -n "$first_ractor" ] || { echo "Could not auto-detect baseline; set BASELINE_REF=<sha>." >&2; return 1; }
    ref="$(git rev-parse "${first_ractor}^")"
  fi
  echo "Baseline:   $(git log -1 --format='%h %s' "$ref")" >&2
  echo "Experiment: $(git log -1 --format='%h %s' HEAD)" >&2

  WT_PARENT="$(mktemp -d)"
  WT="$WT_PARENT/wb-baseline"
  echo "== Creating baseline worktree ==" >&2
  git worktree add -f "$WT" "$ref" >/dev/null 2>&1
  cp "$APP_DIR/script/boot_delta.rb" "$WT/script/boot_delta.rb"

  # Normalize cache store so Redis isn't a confound.
  local prod="$WT/config/environments/production.rb"
  if grep -q 'config.cache_store' "$prod"; then
    sed -i.bak 's/^\( *\)config\.cache_store = .*/\1config.cache_store = :null_store/' "$prod"
    rm -f "$prod.bak"
  fi

  echo "== bundle install (baseline) -- may take a minute ==" >&2
  if ! ( cd "$WT" && bundle install ) >/dev/null 2>&1; then
    echo "baseline bundle install failed:" >&2
    ( cd "$WT" && bundle install ) 2>&1 | tail -15
    return 1
  fi

  local base_out exp_out
  base_out="$(mktemp)"; exp_out="$(mktemp)"; TMPFILES+=("$base_out" "$exp_out")

  local dir label out i
  for pair in "$WT:baseline:$base_out" "$APP_DIR:experiment:$exp_out"; do
    dir="${pair%%:*}"; rest="${pair#*:}"; label="${rest%%:*}"; out="${rest#*:}"
    : > "$out"
    echo "== Booting $label x$BOOT_RUNS ==" >&2
    for i in $(seq 1 "$BOOT_RUNS"); do
      if line="$(cd "$dir" && ruby script/boot_delta.rb 2>/dev/null | grep '^BOOTDELTA')"; then
        echo "$line" >> "$out"
      fi
      echo "  $label run $i/$BOOT_RUNS" >&2
    done
  done
  echo >&2

  ruby - "$base_out" "$exp_out" <<'RUBY'
base = File.readlines(ARGV[0]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
exp  = File.readlines(ARGV[1]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
abort "no successful boot runs" if base.empty? || exp.empty?
def med(xs) = (s = xs.sort; s.size.odd? ? s[s.size/2] : (s[s.size/2-1]+s[s.size/2])/2.0)
def col(rows, i) = rows.map { |r| r[i] }
b_boot = med(col(base,0)); b_rss = med(col(base,6))
e_boot = med(col(exp,0));  e_rss = med(col(exp,6))
e_full = med(exp.map { |r| r[0]+r[2] }); e_rss2 = med(col(exp,7))
e_rz = med(col(exp,2)); e_bf = med(col(exp,3)); e_gf = med(col(exp,4)); e_on = med(col(exp,5))
n = [base.size, exp.size].min
printf("Boot comparison (median of %d boots/side, production)\n\n", n)
printf("%-42s %10s %10s\n", "", "boot ms", "RSS MB")
printf("%-42s %10s %10s\n", "-"*42, "-"*10, "-"*10)
printf("%-42s %10.1f %10.1f\n", "baseline (main, no Ractor code)", b_boot, b_rss)
printf("%-42s %10.1f %10.1f\n", "experiment, base only (no ractorize!)", e_boot, e_rss)
printf("%-42s %10.1f %10.1f\n", "experiment, full (+ ractorize!)", e_full, e_rss2)
puts
printf("Our code's effect on base boot : %+.1f ms (%+.1f%%), RSS %+.1f MB\n",
       e_boot-b_boot, (e_boot-b_boot)/b_boot*100, e_rss-b_rss)
printf("ractorize! delta (server-only) : %+.1f ms (%+.1f%%), RSS %+.1f MB\n",
       e_rz, e_rz/e_boot*100, e_rss2-e_rss)
printf("  before_freeze (warming)      : %8.1f ms\n", e_bf)
printf("  graph_freeze (make_shareable): %8.1f ms\n", e_gf)
printf("  on_freeze                    : %8.1f ms\n", e_on)
puts
puts "Caveat: baseline & experiment lockfiles differ slightly (Rails main commit +"
puts "other gem versions), so small base-boot deltas are within noise/version drift."
RUBY

  # Free the worktree before phase 2.
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT_PARENT"
  WT=""; WT_PARENT=""
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
    echo "== [$label] resetting DB (empty, for /first_run) ==" >&2
    reset_db
    echo "== [$label] booting server ==" >&2
    rm -f /tmp/bench_server.log
    ( env "$@" bin/rails server -p "$PORT" -b 127.0.0.1 >/tmp/bench_server.log 2>&1 ) &
    SERVER_PID=$!
    if ! wait_ready; then echo "[$label] server did not become ready:" >&2; tail -15 /tmp/bench_server.log >&2; return 1; fi
    echo "== [$label] probing (N=$N warmup=$WARMUP N_POST=$N_POST) ==" >&2
    MODE="$label" PORT="$PORT" N="$N" WARMUP="$WARMUP" N_POST="$N_POST" POST_WARMUP="$POST_WARMUP" \
      ruby script/latency_probe.rb >> "$out"
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
    SERVER_PID=""
    sleep 1
  }

  run_mode base   RACTOR_MODE=0
  run_mode ractor RACTOR_METRICS=1
  echo >&2

  ruby - "$out" <<'RUBY'
rows = File.readlines(ARGV[0]).map { |l| l.strip.split(",") }.select { |r| r[0] == "LAT" }
by = Hash.new { |h, k| h[k] = {} }
rows.each { |r| by[r[2]][r[1]] = r }
order = ["/up", "/first_run", "POST /first_run", "/"]
puts "Concurrency-1 latency: base (no Ractor) vs ractor  [client-side ms]"
puts
printf("%-16s %-7s %8s %8s %8s %8s %9s %9s %9s  %s\n",
       "endpoint", "mode", "p50", "p90", "p99", "max", "disp", "main", "worker", "n")
printf("%s\n", "-"*92)
order.each do |ep|
  next unless by.key?(ep)
  %w[base ractor].each do |m|
    r = by[ep][m] or next
    disp = m == "ractor" ? r[12] : "-"
    main = m == "ractor" ? r[10] : "-"
    wrk  = m == "ractor" ? r[11] : "-"
    printf("%-16s %-7s %8s %8s %8s %8s %9s %9s %9s  %s\n", ep, m, r[4], r[5], r[6], r[7], disp, main, wrk, r[3])
  end
  b = by[ep]["base"]; x = by[ep]["ractor"]
  if b && x && b[4].to_f > 0
    d = x[4].to_f - b[4].to_f
    printf("%-16s %-7s p50 %+.2f ms (%+.1f%%)   [server wall %s ms, app %s ms]\n",
           "", "delta", d, (d/b[4].to_f*100), x[8], x[9])
  end
  puts
end
puts "Notes: concurrency 1 (no queueing) -- per-request overhead floor, not the"
puts "contention story. GET /first_run = setup form (empty DB); POST /first_run ="
puts "the write path, DB wiped before each sample (n small, heavy request). 'disp' ="
puts "main-Ractor dispatches/req; 'main' = ms on main; 'worker' = worker-Ractor app time."
RUBY
}

[ "${SKIP_BOOT:-}"    = "1" ] || phase_boot
[ "${SKIP_LATENCY:-}" = "1" ] || phase_latency
