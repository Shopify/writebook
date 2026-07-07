#!/usr/bin/env bash
# Memory to saturate N cores on /up: Puma cluster vs Kino (Ractor-native server).
#
#   puma-cluster : the ec-baseline branch (vanilla Writebook, no Ractor) in a
#                  worktree, WEB_CONCURRENCY=N processes, RAILS_MAX_THREADS=1.
#   kino         : this build via Kino (Rust front-end + N worker Ractors in ONE
#                  process), mode :ractor, workers N -- measured with YJIT ON
#                  and OFF (NO_YJIT=1) to isolate YJIT's stop-the-world barrier,
#                  which serializes Ractors and collapses multi-core throughput.
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
boot_kino() { # $1=workers $2=extra env (e.g. NO_YJIT=1) : sets $MASTER (single kino process)
  kill_port; rm -f /tmp/mem_server.log
  ( cd "$APP_DIR" && exec env ${2:-} bundle exec kino -m ractor -w "$1" -t 1 -b 127.0.0.1 -p "$PORT" config_kino.ru ) > /tmp/mem_server.log 2>&1 &
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

printf "Saturate N cores on /up: Puma cluster (%s) vs Kino Ractors (YJIT on / off)  (load %ss)\n" "$BASELINE_BRANCH" "$LOAD_SECS"
printf "ruby: %s\n\n" "$(ruby -e 'print RUBY_DESCRIPTION' 2>/dev/null)"
setup
: > "$rows"
for N in $SWEEP; do
  conc=$(( N * 4 ))
  echo "== N=$N: cluster ($BASELINE_BRANCH, WEB_CONCURRENCY=$N) ==" >&2
  boot_puma "$WT" "WEB_CONCURRENCY=$N RAILS_MAX_THREADS=1"; pprocs=$(nprocs "$MASTER")
  read -r rss rps stat bad p50 p99 <<<"$(measure "$MASTER" "$conc")"
  echo "$N puma-cluster $pprocs $rss $rps $stat $bad $p50 $p99" >> "$rows"; kill_port
  echo "== N=$N: kino (ractor, workers=$N, YJIT on) ==" >&2
  boot_kino "$N"
  read -r rss rps stat bad p50 p99 <<<"$(measure "$MASTER" "$conc")"
  echo "$N kino 1 $rss $rps $stat $bad $p50 $p99" >> "$rows"; kill_port
  echo "== N=$N: kino (ractor, workers=$N, YJIT off) ==" >&2
  boot_kino "$N" "NO_YJIT=1"
  read -r rss rps stat bad p50 p99 <<<"$(measure "$MASTER" "$conc")"
  echo "$N kino-noyjit 1 $rss $rps $stat $bad $p50 $p99" >> "$rows"; kill_port
done
echo >&2

ruby - "$rows" "$BASELINE_BRANCH" <<'RUBY'
rows = File.readlines(ARGV[0]).map(&:split)  # N config procs rss rps stat bad p50 p99
base = ARGV[1]
def c(s, code) = $stdout.tty? ? "\e[#{code}m#{s}\e[0m" : s.to_s
ORDER  = %w[puma-cluster kino kino-noyjit]
LABELS = { "puma-cluster" => "puma-cluster", "kino" => "kino (YJIT on)", "kino-noyjit" => "kino (YJIT off)" }
failed = false
printf("%-4s  %-16s %5s %8s %9s %7s %7s %8s   %s\n", "N", "config", "procs", "rss(MB)", "rps", "p50", "p99", "MB/rps", "mem gain")
puts "-" * 94
ns = rows.map { |r| r[0].to_i }.uniq.sort
ns.each do |n|
  pc = rows.find { |r| r[0].to_i == n && r[1] == "puma-cluster" }
  base_rss = (pc && pc[5] != "CRASH") ? pc[3].to_f : nil
  ORDER.each do |cfg|
    r = rows.find { |x| x[0].to_i == n && x[1] == cfg }
    next unless r
    nlabel = cfg == ORDER.first ? n.to_s : ""
    if r[5] == "CRASH"
      printf("%-4s  %-16s %5s   #{c("*** CRASHED under load (%s failed reqs) ***", 31)}\n", nlabel, LABELS[cfg], r[2], r[6]); failed = true; next
    end
    eff  = r[4].to_f > 0 ? format("%.2f", r[3].to_f / r[4].to_f) : "-"
    gain = (base_rss && cfg != "puma-cluster" && r[3].to_f > 0) ? format("%.2fx", base_rss / r[3].to_f) : ""
    printf("%-4s  %-16s %5s %8s %9s %7s %7s %8s   %s\n", nlabel, LABELS[cfg], r[2], r[3], r[4], r[7], r[8], eff, gain)
  end
  puts
end
# throughput scaling per config (rps at max N / rps at min N)
if ns.size > 1
  lo, hi = ns.first, ns.last
  ORDER.each do |cfg|
    a = rows.find { |r| r[0].to_i == lo && r[1] == cfg && r[5] != "CRASH" }
    b = rows.find { |r| r[0].to_i == hi && r[1] == cfg && r[5] != "CRASH" }
    next unless a && b && a[4].to_f > 0
    f = b[4].to_f / a[4].to_f
    tag = f >= 1 ? format("%.1fx scale-up", f) : format("%.1fx COLLAPSE", 1 / f)
    printf("%-16s N=%d->%d:  %s rps -> %s rps   (%s)\n", LABELS[cfg], lo, hi, a[4], b[4], tag)
  end
end
puts
puts "cluster = #{base} (vanilla Writebook, N processes); kino = this build via Kino (N worker Ractors, 1 process)."
puts "YJIT on vs off isolates YJIT's rb_jit_vm_lock_then_barrier (stop-the-world) contention across Ractors."
puts "rss = peak RSS under load; p50/p99 = client latency (ms); mem gain = cluster rss / kino rss."
exit 1 if failed
RUBY
