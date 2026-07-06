#!/usr/bin/env bash
# Memory-to-saturate-N-cores: Puma cluster (N processes) vs Ractor pool (1
# process, N worker Ractors), both serving the same concurrent authenticated
# GET / load on the same Ruby.
#
#   Puma cluster : PUMA_WORKERS=N, RAILS_MAX_THREADS=1, RACTOR_MODE=0 (normal app)
#   Ractor pool  : RACTOR_POOL=N,  RAILS_MAX_THREADS=N, RACTOR_MODE=1 (single proc)
#
# Reports peak RSS under load + throughput for each, and the memory gain.
# Requires: a booted ruby env (source it first) with the app bundle installed,
# and precompiled assets. Usage:  script/memory_saturation.sh [N ...]   (default: 1 2 4 8)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-3996}"
LOAD_SECS="${LOAD_SECS:-10}"
SWEEP="${*:-1 2 4 8}"
export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1
UA="Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"
COOKIE_FILE=/tmp/mem_cookie.txt
tmpout=$(mktemp)

kill_port() { lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true; sleep 1; }
wait_up() { for _ in $(seq 1 90); do curl -s -o /dev/null -H "User-Agent: $UA" "http://127.0.0.1:$PORT/up" 2>/dev/null && return 0; sleep 1; done; return 1; }
rss_mb() { # sum RSS (MB) of master $1 + its worker children
  local m=$1 kids; kids=$(pgrep -P "$m" 2>/dev/null || true)
  ps -o rss= -p "$m" $kids 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}'
}
nprocs() { local m=$1; echo $(( 1 + $(pgrep -P "$m" 2>/dev/null | wc -l | tr -d ' ') )); }

boot() { # $1=extra env : returns master pid via $MASTER
  kill_port
  rm -f /tmp/mem_server.log
  env $1 PORT="$PORT" nohup bundle exec puma -p "$PORT" -e production config.ru > /tmp/mem_server.log 2>&1 &
  MASTER=$!
  disown
  wait_up || { echo "server failed to boot:"; tail -8 /tmp/mem_server.log; exit 1; }
}

setup_data() { # reset DB + onboard once; cookie reused for all runs (shared secret+DB)
  DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rails db:reset >/dev/null 2>&1
  boot "RACTOR_MODE=0"
  PORT="$PORT" ruby script/get_cookie_setup.rb > "$COOKIE_FILE" 2>/dev/null
  kill_port
  [ -s "$COOKIE_FILE" ] || { echo "onboarding failed"; exit 1; }
}

measure() { # $1=master pid, $2=conc  ; echoes "rssMB rps"
  local m=$1 conc=$2 cookie; cookie=$(cat "$COOKIE_FILE")
  PORT="$PORT" COOKIE="$cookie" DURATION=2 CONC="$conc" ruby script/mem_load.rb >/dev/null 2>&1 # warm
  PORT="$PORT" COOKIE="$cookie" DURATION="$LOAD_SECS" CONC="$conc" ruby script/mem_load.rb > "$tmpout" 2>&1 &
  local lp=$! peak=0 cur
  while kill -0 "$lp" 2>/dev/null; do cur=$(rss_mb "$m"); [ "${cur:-0}" -gt "$peak" ] && peak=$cur; sleep 0.4; done
  wait "$lp"
  local rps; rps=$(grep -o 'rps=[0-9.]*' "$tmpout" | cut -d= -f2)
  echo "$peak ${rps:-0}"
}

printf "Memory to saturate N cores: Puma cluster vs Ractor pool  (load %ss, port %s)\n" "$LOAD_SECS" "$PORT"
printf "ruby: %s\n\n" "$(ruby -e 'print RUBY_DESCRIPTION' 2>/dev/null)"
setup_data
printf "%-4s  %-14s %6s %8s %9s %8s   %s\n" "N" "config" "procs" "rss(MB)" "rps" "MB/rps" "mem gain"
printf -- "------------------------------------------------------------------------------\n"
first_p=""; first_r=""; last_p=""; last_r=""; first_n=""; last_n=""
for N in $SWEEP; do
  conc=$(( N * 4 ))
  boot "RACTOR_MODE=0 PUMA_WORKERS=$N RAILS_MAX_THREADS=1"
  read -r prss prps <<<"$(measure "$MASTER" "$conc")"; pprocs=$(nprocs "$MASTER"); kill_port
  boot "RACTOR_MODE=1 RACTOR_POOL=$N RAILS_MAX_THREADS=$N"
  read -r rrss rrps <<<"$(measure "$MASTER" "$conc")"; kill_port
  gain=$(awk -v p="$prss" -v r="$rrss" 'BEGIN{ if (r>0) printf "%.2fx", p/r; else print "-" }')
  peff=$(awk -v m="$prss" -v q="$prps" 'BEGIN{ if (q>0) printf "%.2f", m/q; else print "-" }')
  reff=$(awk -v m="$rrss" -v q="$rrps" 'BEGIN{ if (q>0) printf "%.2f", m/q; else print "-" }')
  printf "%-4s  %-14s %6s %8s %9s %8s\n"        "$N" "puma-cluster" "$pprocs" "$prss" "$prps" "$peff"
  printf "%-4s  %-14s %6s %8s %9s %8s   %s\n"    ""  "ractor-pool"  "1"        "$rrss" "$rrps" "$reff" "$gain"
  [ -z "$first_n" ] && { first_n=$N; first_p=$prss; first_r=$rrss; }
  last_n=$N; last_p=$prss; last_r=$rrss
done
rm -f "$tmpout"
if [ "$first_n" != "$last_n" ]; then
  echo
  awk -v fp="$first_p" -v lp="$last_p" -v fr="$first_r" -v lr="$last_r" -v fn="$first_n" -v ln="$last_n" \
    'BEGIN{ d=ln-fn; printf "per added core (N=%s..%s):  puma-cluster +%.0f MB/core   ractor-pool +%.0f MB/core\n", fn, ln, (lp-fp)/d, (lr-fr)/d }'
fi
echo
echo "rss    = peak resident memory under load (cluster = master + workers summed)."
echo "MB/rps = memory per unit throughput (lower = more efficient)."
echo "mem gain = puma-cluster rss / ractor-pool rss (higher = Ractors use less RAM)."
echo "NOTE: ractor-pool throughput is currently capped by the single main-dispatch"
echo "thread (all DB funnels through one executor); per-Ractor DB connections would"
echo "let it scale like the cluster while keeping the flat memory curve."
