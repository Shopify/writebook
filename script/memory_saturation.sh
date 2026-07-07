#!/usr/bin/env bash
# Memory to saturate N cores on /up: Puma cluster vs Kino (Ractor-native server).
#
#   puma-cluster : the ec-baseline branch (vanilla Writebook, no Ractor) in a
#                  worktree, WEB_CONCURRENCY=N processes, RAILS_MAX_THREADS=1.
#   kino         : this build via Kino (Rust front-end + N worker Ractors in ONE
#                  process), mode :ractor, workers N.
#
# Both serve the same concurrent /up load (no DB, no auth) on the same Ruby.
# Reports peak RSS under load, throughput, latency, and the memory gain.
# Requires the kino gem (Gemfile) and config_kino.ru; runs on Ruby master.
# Usage:  script/memory_saturation.sh [N ...]           (default: 1 2 4 8)
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$APP_DIR"

PORT="${PORT:-3996}"
LOAD_SECS="${LOAD_SECS:-10}"
SWEEP="${*:-1 2 4 8}"
BASELINE_BRANCH="${BASELINE_BRANCH:-ec-baseline}"
ENDPOINT="/up"
export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1
UA="Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"
tmpout=$(mktemp); rows=$(mktemp)
WT="" ; WT_PARENT=""

kill_port() { lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true; sleep 1; }
cleanup() {
  kill_port; pkill -f "kino" 2>/dev/null || true
  [ -n "$WT" ] && git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  [ -n "$WT_PARENT" ] && rm -rf "$WT_PARENT"
  rm -f "$tmpout" "$rows"
}
trap cleanup EXIT

wait_up() { for _ in $(seq 1 90); do curl -s -o /dev/null -H "User-Agent: $UA" "http://127.0.0.1:$PORT/up" 2>/dev/null && return 0; sleep 1; done; return 1; }
alive() { for _ in 1 2 3 4 5; do curl -s -o /dev/null "http://127.0.0.1:$PORT/up" 2>/dev/null && return 0; sleep 0.3; done; return 1; }
rss_mb() { local m=$1 kids; kids=$(pgrep -P "$m" 2>/dev/null || true); ps -o rss= -p "$m" $kids 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}'; }
nprocs() { local m=$1; echo $(( 1 + $(pgrep -P "$m" 2>/dev/null | wc -l | tr -d ' ') )); }

boot_puma() { # $1=dir $2=extra env : sets $MASTER (puma master, cwd=$1)
  kill_port; rm -f /tmp/mem_server.log
  ( cd "$1" && exec env $2 PORT="$PORT" bundle exec puma -p "$PORT" -e production config.ru ) > /tmp/mem_server.log 2>&1 &
  MASTER=$!; disown
  wait_up || { echo "puma failed to boot ($1):"; tail -8 /tmp/mem_server.log; exit 1; }
}
boot_kino() { # $1=workers : sets $MASTER (single kino process, cwd=$APP_DIR)
  kill_port; rm -f /tmp/mem_server.log
  ( cd "$APP_DIR" && exec bundle exec kino -m ractor -w "$1" -t 1 -b 127.0.0.1 -p "$PORT" config_kino.ru ) > /tmp/mem_server.log 2>&1 &
  MASTER=$!; disown
  wait_up || { echo "kino failed to boot:"; tail -12 /tmp/mem_server.log; exit 1; }
}

setup() {
  bundle exec ruby -e 'require "kino"' >/dev/null 2>&1 || { echo "kino not installed (add the kino gem from the Gemfile and bundle install)"; exit 1; }
  echo "== preparing baseline worktree ($BASELINE_BRANCH) ==" >&2
  local ref="$BASELINE_BRANCH"
  git rev-parse --verify "$ref" >/dev/null 2>&1 || ref="origin/$BASELINE_BRANCH"
  git rev-parse --verify "$ref" >/dev/null 2>&1 || { echo "baseline branch not found ('$BASELINE_BRANCH')."; exit 1; }
  WT_PARENT="$(mktemp -d)"; WT="$WT_PARENT/wb-baseline"
  git worktree add -f "$WT" "$ref" >/dev/null 2>&1
  ( cd "$WT" && bundle install \
      && RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile \
      && DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:reset ) >/dev/null 2>&1 \
    || { echo "baseline worktree prep failed"; exit 1; }
  RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile >/dev/null 2>&1 || true
  DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:reset >/dev/null 2>&1 || true
}

measure() { # $1=master $2=conc ; echoes "rssMB rps status bad p50 p99"  (endpoint = /up, no cookie)
  local m=$1 conc=$2
  PORT="$PORT" ENDPOINT="$ENDPOINT" DURATION=2 CONC="$conc" ruby "$APP_DIR/script/mem_load.rb" >/dev/null 2>&1 # warm
  PORT="$PORT" ENDPOINT="$ENDPOINT" DURATION="$LOAD_SECS" CONC="$conc" ruby "$APP_DIR/script/mem_load.rb" > "$tmpout" 2>&1 &
  local lp=$! peak=0 cur
  while kill -0 "$lp" 2>/dev/null; do
    kill -0 "$m" 2>/dev/null && { cur=$(rss_mb "$m"); [ "${cur:-0}" -gt "$peak" ] && peak=$cur; }
    sleep 0.4
  done
  wait "$lp"
  local rps bad p50 p99 status
  rps=$(grep -o 'rps=[0-9.]*' "$tmpout" | cut -d= -f2); bad=$(grep -o 'bad=[0-9]*' "$tmpout" | cut -d= -f2)
  p50=$(grep -o 'p50=[0-9.]*' "$tmpout" | cut -d= -f2); p99=$(grep -o 'p99=[0-9.]*' "$tmpout" | cut -d= -f2)
  status=OK
  if [ "$(grep -c '\[BUG\]' /tmp/mem_server.log)" -gt 0 ] || [ "${bad:-0}" -gt 50 ] || ! alive; then status=CRASH; fi
  echo "$peak ${rps:-0} $status ${bad:-0} ${p50:-0} ${p99:-0}"
}

printf "Memory to saturate N cores on /up: Puma cluster (%s) vs Kino  (load %ss)\n" "$BASELINE_BRANCH" "$LOAD_SECS"
printf "ruby: %s\n\n" "$(ruby -e 'print RUBY_DESCRIPTION' 2>/dev/null)"
setup
: > "$rows"
for N in $SWEEP; do
  conc=$(( N * 4 ))
  echo "== N=$N: cluster ($BASELINE_BRANCH, WEB_CONCURRENCY=$N) ==" >&2
  boot_puma "$WT" "WEB_CONCURRENCY=$N RAILS_MAX_THREADS=1"; pprocs=$(nprocs "$MASTER")
  read -r rss rps stat bad p50 p99 <<<"$(measure "$MASTER" "$conc")"
  echo "$N puma-cluster $pprocs $rss $rps $stat $bad $p50 $p99" >> "$rows"; kill_port
  echo "== N=$N: kino (ractor, workers=$N) ==" >&2
  boot_kino "$N"
  read -r rss rps stat bad p50 p99 <<<"$(measure "$MASTER" "$conc")"
  echo "$N kino 1 $rss $rps $stat $bad $p50 $p99" >> "$rows"; kill_port
done
echo >&2

ruby - "$rows" "$BASELINE_BRANCH" <<'RUBY'
rows = File.readlines(ARGV[0]).map(&:split)  # N config procs rss rps stat bad p50 p99
base = ARGV[1]
def c(s, code) = $stdout.tty? ? "\e[#{code}m#{s}\e[0m" : s.to_s
failed = false
printf("%-4s  %-14s %5s %8s %8s %7s %7s %7s   %s\n", "N", "config", "procs", "rss(MB)", "rps", "p50", "p99", "MB/rps", "mem gain")
puts "-" * 86
fp=nil; lp=nil; fk=nil; lk=nil; fn=nil; ln=nil
rows.map { |r| r[0].to_i }.uniq.sort.each do |n|
  pc = rows.find { |r| r[0].to_i == n && r[1] == "puma-cluster" }
  ki = rows.find { |r| r[0].to_i == n && r[1] == "kino" }
  if pc && pc[5] == "CRASH"
    printf("%-4s  %-14s %5s   #{c("*** CRASHED under load (%s failed reqs) ***", 31)}\n", n, "puma-cluster", pc[2], pc[6]); failed = true
  elsif pc
    peff = pc[4].to_f > 0 ? format("%.2f", pc[3].to_f / pc[4].to_f) : "-"
    printf("%-4s  %-14s %5s %8s %8s %7s %7s %7s\n", n, "puma-cluster", pc[2], pc[3], pc[4], pc[7], pc[8], peff)
  end
  if ki && ki[5] == "CRASH"
    printf("%-4s  %-14s %5s   #{c("*** CRASHED under load (%s failed reqs) ***", 31)}\n", "", "kino", "1", ki[6]); failed = true
  elsif ki
    keff = ki[4].to_f > 0 ? format("%.2f", ki[3].to_f / ki[4].to_f) : "-"
    gain = (pc && pc[5] != "CRASH" && ki[3].to_f > 0) ? format("%.2fx", pc[3].to_f / ki[3].to_f) : "-"
    printf("%-4s  %-14s %5s %8s %8s %7s %7s %7s   %s\n", "", "kino", "1", ki[3], ki[4], ki[7], ki[8], keff, gain)
    if pc && pc[5] != "CRASH"
      if fn.nil? then fn = n; fp = pc[3].to_f; fk = ki[3].to_f end
      ln = n; lp = pc[3].to_f; lk = ki[3].to_f
    end
  end
end
if fn && ln && ln != fn
  d = ln - fn
  printf("\nper added core (N=%d..%d):  puma-cluster +%.0f MB/core   kino +%.0f MB/core\n", fn, ln, (lp - fp) / d, (lk - fk) / d)
end
puts
puts "cluster = #{base} (vanilla Writebook, N processes); kino = this build via Kino (N worker Ractors, 1 process)."
puts "rss = peak RSS under load (cluster = master + workers summed; kino = one process)."
puts "p50/p99 = client latency (ms) under load; mem gain = cluster rss / kino rss (higher = Kino uses less RAM)."
exit 1 if failed
RUBY
