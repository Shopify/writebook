#!/usr/bin/env bash
# Memory-to-saturate-N-cores: Puma cluster vs Ractor pool, both serving the same
# concurrent authenticated GET / load on the same Ruby.
#
#   Puma cluster : the ec-baseline branch (vanilla Writebook, no Ractor) in a
#                  worktree, WEB_CONCURRENCY=N processes, RAILS_MAX_THREADS=1.
#   Ractor pool  : this build (HEAD), 1 process, RACTOR_POOL=N worker Ractors,
#                  RAILS_MAX_THREADS=N, RACTOR_MODE=1.
#
# Reports peak RSS under load + throughput for each, and the memory gain.
# Requires Ruby master (see README). Manages its own baseline worktree.
# Usage:  script/memory_saturation.sh [N ...]           (default: 1 2 4 8)
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$APP_DIR"

PORT="${PORT:-3996}"
LOAD_SECS="${LOAD_SECS:-10}"
SWEEP="${*:-1 2 4 8}"
BASELINE_BRANCH="${BASELINE_BRANCH:-ec-baseline}"
export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1
UA="Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"
COOKIE_BASE=/tmp/mem_cookie_base.txt   # cluster (vanilla worktree)
COOKIE_POOL=/tmp/mem_cookie_pool.txt   # pool (experiment / HEAD)
ENDPOINTS="/up /"                      # measured for every (N, config)
tmpout=$(mktemp); rows=$(mktemp)
WT="" ; WT_PARENT=""

kill_port() { lsof -ti tcp:"$PORT" 2>/dev/null | xargs -r kill -9 2>/dev/null || true; sleep 1; }
cleanup() {
  kill_port
  [ -n "$WT" ] && git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  [ -n "$WT_PARENT" ] && rm -rf "$WT_PARENT"
  rm -f "$tmpout" "$rows"
}
trap cleanup EXIT

wait_up() { for _ in $(seq 1 90); do curl -s -o /dev/null -H "User-Agent: $UA" "http://127.0.0.1:$PORT/up" 2>/dev/null && return 0; sleep 1; done; return 1; }
alive() { for _ in 1 2 3 4 5; do curl -s -o /dev/null "http://127.0.0.1:$PORT/up" 2>/dev/null && return 0; sleep 0.3; done; return 1; } # retried: avoids racing a post-load stall
rss_mb() { local m=$1 kids; kids=$(pgrep -P "$m" 2>/dev/null || true); ps -o rss= -p "$m" $kids 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}'; }
nprocs() { local m=$1; echo $(( 1 + $(pgrep -P "$m" 2>/dev/null | wc -l | tr -d ' ') )); }

boot() { # $1=dir $2=extra env : sets $MASTER (puma master pid, cwd=$1)
  kill_port
  rm -f /tmp/mem_server.log
  ( cd "$1" && exec env $2 PORT="$PORT" bundle exec puma -p "$PORT" -e production config.ru ) > /tmp/mem_server.log 2>&1 &
  MASTER=$!
  disown
  wait_up || { echo "server failed to boot ($1):"; tail -8 /tmp/mem_server.log; exit 1; }
}

onboard() { # $1=cookie file ; server must be up
  PORT="$PORT" ruby "$APP_DIR/script/get_cookie_setup.rb" > "$1" 2>/dev/null
  [ -s "$1" ] || { echo "onboarding failed"; exit 1; }
}

setup() {
  echo "== preparing baseline worktree ($BASELINE_BRANCH) ==" >&2
  local ref="$BASELINE_BRANCH"
  git rev-parse --verify "$ref" >/dev/null 2>&1 || ref="origin/$BASELINE_BRANCH" # fresh clone: remote-tracking ref
  git rev-parse --verify "$ref" >/dev/null 2>&1 || { echo "baseline branch not found (need '$BASELINE_BRANCH' locally or on origin)."; exit 1; }
  WT_PARENT="$(mktemp -d)"; WT="$WT_PARENT/wb-baseline"
  git worktree add -f "$WT" "$ref" >/dev/null 2>&1
  ( cd "$WT" && bundle install \
      && RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile \
      && DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:reset ) >/dev/null 2>&1 \
    || { echo "baseline worktree prep failed"; exit 1; }
  RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 bin/rails assets:precompile >/dev/null 2>&1 || true

  echo "== onboarding baseline (cluster) ==" >&2
  boot "$WT" "" ; onboard "$COOKIE_BASE" ; kill_port
  echo "== onboarding experiment (pool) ==" >&2
  ( DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:reset ) >/dev/null 2>&1
  boot "$APP_DIR" "RACTOR_MODE=0" ; onboard "$COOKIE_POOL" ; kill_port
}

measure() { # $1=master $2=conc $3=cookie-file $4=endpoint ; echoes "rssMB rps status bad"
  local m=$1 conc=$2 cookie ep="$4"; cookie=$(cat "$3")
  PORT="$PORT" COOKIE="$cookie" ENDPOINT="$ep" DURATION=2 CONC="$conc" ruby "$APP_DIR/script/mem_load.rb" >/dev/null 2>&1 # warm
  PORT="$PORT" COOKIE="$cookie" ENDPOINT="$ep" DURATION="$LOAD_SECS" CONC="$conc" ruby "$APP_DIR/script/mem_load.rb" > "$tmpout" 2>&1 &
  local lp=$! peak=0 cur
  while kill -0 "$lp" 2>/dev/null; do
    kill -0 "$m" 2>/dev/null && { cur=$(rss_mb "$m"); [ "${cur:-0}" -gt "$peak" ] && peak=$cur; }
    sleep 0.4
  done
  wait "$lp"
  local rps bad status; rps=$(grep -o 'rps=[0-9.]*' "$tmpout" | cut -d= -f2); bad=$(grep -o 'bad=[0-9]*' "$tmpout" | cut -d= -f2)
  # Never report memory/throughput for a run whose server died -- that would
  # silently hide a crash.
  status=OK
  if [ "$(grep -c '\[BUG\]' /tmp/mem_server.log)" -gt 0 ] || [ "${bad:-0}" -gt 50 ] || ! alive; then
    status=CRASH
  fi
  echo "$peak ${rps:-0} $status ${bad:-0}"
}

printf "Memory to saturate N cores: Puma cluster (%s, vanilla) vs Ractor pool (HEAD)  (load %ss)\n" "$BASELINE_BRANCH" "$LOAD_SECS"
printf "ruby: %s\n\n" "$(ruby -e 'print RUBY_DESCRIPTION' 2>/dev/null)"
setup
: > "$rows"
for N in $SWEEP; do
  conc=$(( N * 4 ))
  echo "== N=$N: cluster ($BASELINE_BRANCH, WEB_CONCURRENCY=$N) ==" >&2
  boot "$WT" "WEB_CONCURRENCY=$N RAILS_MAX_THREADS=1"; pprocs=$(nprocs "$MASTER")
  for ep in $ENDPOINTS; do
    read -r rss rps stat bad <<<"$(measure "$MASTER" "$conc" "$COOKIE_BASE" "$ep")"
    echo "$ep $N puma-cluster $pprocs $rss $rps $stat $bad" >> "$rows"
  done
  kill_port
  echo "== N=$N: ractor-pool (RACTOR_POOL=$N) ==" >&2
  boot "$APP_DIR" "RACTOR_MODE=1 RACTOR_POOL=$N RAILS_MAX_THREADS=$N"
  for ep in $ENDPOINTS; do
    read -r rss rps stat bad <<<"$(measure "$MASTER" "$conc" "$COOKIE_POOL" "$ep")"
    echo "$ep $N ractor-pool 1 $rss $rps $stat $bad" >> "$rows"
  done
  kill_port
done
echo >&2

ruby - "$rows" "$BASELINE_BRANCH" <<'RUBY'
rows = File.readlines(ARGV[0]).map(&:split)  # ep N config procs rss rps stat bad
base = ARGV[1]
def c(s, code) = $stdout.tty? ? "\e[#{code}m#{s}\e[0m" : s.to_s
descr = { "/up" => "healthcheck, no DB", "/" => "authenticated: DB + render" }
failed = false
["/up", "/"].each do |ep|
  ers = rows.select { |r| r[0] == ep }
  next if ers.empty?
  puts
  puts "endpoint #{ep}  (#{descr[ep] || ""})"
  printf("%-4s  %-14s %6s %8s %9s %8s   %s\n", "N", "config", "procs", "rss(MB)", "rps", "MB/rps", "mem gain")
  puts "-" * 78
  fp=nil; lp=nil; fr=nil; lr=nil; fn=nil; ln=nil
  ers.map { |r| r[1].to_i }.uniq.sort.each do |n|
    pc = ers.find { |r| r[1].to_i == n && r[2] == "puma-cluster" }
    rp = ers.find { |r| r[1].to_i == n && r[2] == "ractor-pool" }
    if pc && pc[6] == "CRASH"
      printf("%-4s  %-14s %6s   #{c("*** CRASHED under load (%s failed reqs) ***", 31)}\n", n, "puma-cluster", pc[3], pc[7]); failed = true
    elsif pc
      peff = pc[5].to_f > 0 ? format("%.2f", pc[4].to_f / pc[5].to_f) : "-"
      printf("%-4s  %-14s %6s %8s %9s %8s\n", n, "puma-cluster", pc[3], pc[4], pc[5], peff)
    end
    if rp && rp[6] == "CRASH"
      printf("%-4s  %-14s %6s   #{c("*** CRASHED under load (%s failed reqs) ***", 31)}\n", "", "ractor-pool", "1", rp[7]); failed = true
    elsif rp
      reff = rp[5].to_f > 0 ? format("%.2f", rp[4].to_f / rp[5].to_f) : "-"
      gain = (pc && pc[6] != "CRASH" && rp[4].to_f > 0) ? format("%.2fx", pc[4].to_f / rp[4].to_f) : "-"
      printf("%-4s  %-14s %6s %8s %9s %8s   %s\n", "", "ractor-pool", "1", rp[4], rp[5], reff, gain)
      if pc && pc[6] != "CRASH"
        if fn.nil? then fn = n; fp = pc[4].to_f; fr = rp[4].to_f end
        ln = n; lp = pc[4].to_f; lr = rp[4].to_f
      end
    end
  end
  if fn && ln && ln != fn
    d = ln - fn
    printf("\nper added core (N=%d..%d):  puma-cluster +%.0f MB/core   ractor-pool +%.0f MB/core\n", fn, ln, (lp - fp) / d, (lr - fr) / d)
  end
end
puts
puts "cluster = #{base} (vanilla Writebook, N processes); pool = this build (N worker Ractors)."
puts "rss = peak RSS under load (cluster = master + workers summed); MB/rps = memory per rps."
puts "mem gain = puma-cluster rss / ractor-pool rss (higher = Ractors use less RAM)."
puts "NOTE: on / (DB-bound) the pool's throughput is capped by the single main-dispatch"
puts "thread; on /up (no DB) it runs fully parallel. Memory stays flat either way."
exit 1 if failed
RUBY
