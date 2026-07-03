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
lines = File.readlines(ARGV[0]).map { |l| l.strip.split(",") }
rows = lines.select { |r| r[0] == "LAT" }   # LAT,mode,ep,ok,p50,p90,p99,max,wall,app,main,worker,disp
posts = lines.select { |r| r[0] == "POST" }  # POST,mode,ep,ok,ms,wall,app,main,disp
by = Hash.new { |h, k| h[k] = {} }
rows.each { |r| by[r[2]][r[1]] = r }
order = ["/up", "/first_run", "/"]

puts "Concurrency-1 latency: base (no Ractor) vs ractor  [client-side ms]"
puts
printf("%-14s %-7s %8s %8s %8s %8s %9s %8s %9s\n",
       "endpoint", "mode", "p50", "p90", "p99", "max", "disp", "main", "worker")
printf("%s\n", "-" * 84)
order.each do |ep|
  next unless by.key?(ep)
  %w[base ractor].each do |m|
    r = by[ep][m] or next
    disp = m == "ractor" ? r[12] : "-"
    main = m == "ractor" ? r[10] : "-"
    wrk  = m == "ractor" ? r[11] : "-"
    printf("%-14s %-7s %8s %8s %8s %8s %9s %8s %9s\n", ep, m, r[4], r[5], r[6], r[7], disp, main, wrk)
  end
  b = by[ep]["base"]; x = by[ep]["ractor"]
  if b && x
    d = x[4].to_f - b[4].to_f
    printf("%-14s %-7s p50 %+.2f ms (%+.1f%%)   [server wall %s ms, app %s ms]\n",
           "", "delta", d, (d / b[4].to_f * 100), x[8], x[9])
  end
  puts
end

unless posts.empty?
  puts "POST /first_run  (one-shot write path: account+admin+book+cover+demo, n=1)"
  printf("%-7s %10s %10s %10s %10s %8s\n", "mode", "total ms", "wall", "app", "main", "disp")
  posts.each do |r|
    printf("%-7s %10s %10s %10s %10s %8s   (%s)\n", r[1], r[4], r[5], r[6], r[7], r[8], r[3])
  end
  puts
end

puts "Notes: concurrency 1 (no queueing) -- this is the per-request overhead floor,"
puts "not the contention story. DB reset to empty before each mode so /first_run is"
puts "the real onboarding path. 'disp' = main-Ractor dispatches/req; 'main' = ms"
puts "waiting on the main Ractor; 'worker' = app time in the worker Ractor."
RUBY
