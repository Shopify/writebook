#!/usr/bin/env bash
#
# Concurrency-1 latency comparison: the SAME build served with Ractors
# (per-request worker Ractor + dispatch-to-main) vs without (normal Rails on the
# main Ractor). Measures a dispatch gradient of endpoints and prints p50/p90/p99
# side by side, plus the Ractor-mode worker/main/dispatch breakdown.
#
#   script/latency_compare.sh          # defaults: N=200 requests, WARMUP=40
#   N=500 WARMUP=100 script/latency_compare.sh
#
# Requires Ruby 4.x active (chruby 4.0.1). Uses port 3998 by default (PORT=).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

PORT="${PORT:-3998}"
N="${N:-200}"
WARMUP="${WARMUP:-40}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret123456}"
export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1

OUT="$(mktemp)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
  rm -f "$OUT"
}
trap cleanup EXIT

# Reset to an empty DB so GET/POST /first_run is the real onboarding path (the
# form only renders while there are no users). Full drop/recreate/load-schema.
reset_db() {
  DISABLE_DATABASE_ENVIRONMENT_CHECK=1 SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production \
    bin/rails db:reset >/dev/null 2>&1 || { echo "db reset failed" >&2; exit 1; }
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
  rm -f /tmp/lat_server.log
  ( env "$@" bin/rails server -p "$PORT" -b 127.0.0.1 >/tmp/lat_server.log 2>&1 ) &
  SERVER_PID=$!
  if ! wait_ready; then echo "[$label] server did not become ready:" >&2; tail -15 /tmp/lat_server.log >&2; exit 1; fi
  echo "== [$label] probing (N=$N, warmup=$WARMUP) ==" >&2
  MODE="$label" PORT="$PORT" N="$N" WARMUP="$WARMUP" ruby script/latency_probe.rb >> "$OUT"
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
  SERVER_PID=""
  sleep 1
}

run_mode base   RACTOR_MODE=0
run_mode ractor RACTOR_METRICS=1

echo >&2
ruby - "$OUT" <<'RUBY'
rows = File.readlines(ARGV[0]).map { |l| l.strip.split(",") }.select { |r| r[0] == "LAT" }
# LAT,mode,endpoint,ok/total,p50,p90,p99,max,wall,app,main,worker,disp
by = Hash.new { |h, k| h[k] = {} }
rows.each { |r| by[r[2]][r[1]] = r }
order = ["/up", "/first_run", "POST /first_run", "/"]

puts "Concurrency-1 latency: base (no Ractor) vs ractor  [client-side ms]"
puts
printf("%-16s %-7s %8s %8s %8s %8s %9s %9s %9s  %s\n",
       "endpoint", "mode", "p50", "p90", "p99", "max", "disp", "main", "worker", "n")
printf("%s\n", "-" * 92)
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
           "", "delta", d, (d / b[4].to_f * 100), x[8], x[9])
  end
  puts
end
puts "Notes: concurrency 1 (no queueing) -- per-request overhead floor, not the"
puts "contention story. GET /first_run = setup form (empty DB); POST /first_run ="
puts "the write path, with the DB wiped before each sample (n small, heavy request)."
puts "'disp' = main-Ractor dispatches/req; 'main' = ms on the main Ractor; 'worker' ="
puts "app time in the worker Ractor."
RUBY
