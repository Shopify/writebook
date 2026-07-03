#!/usr/bin/env bash
#
# Ractor experiment benchmark -- one command, all results.
#
#   script/benchmark.sh
#
# Phases (skippable):
#   1. BOOT      baseline (pre-Ractor worktree) vs experiment base vs +ractorize!
#   2. LATENCY   concurrency-1 base vs ractor across /up, GET/POST /first_run, /
#   3. SWEEP     throughput + p50/p99 + errors + peak RSS vs concurrency, base vs
#                ractor, for /up and authenticated / (needs `oha`).
#
# Config via env (all optional):
#   BOOT_RUNS=5  N=150  WARMUP=40  N_POST=15  POST_WARMUP=3  PORT=3998
#   SWEEP_CONC="1 2 4 8 16"  SWEEP_DURATION=3s
#   BASELINE_REF=<sha>       # override auto-detected pre-Ractor commit
#   SKIP_BOOT=1 / SKIP_LATENCY=1 / SKIP_SWEEP=1
#
# Requires Ruby 4.x active (chruby 4.0.1). SWEEP requires `oha` on PATH.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

BOOT_RUNS="${BOOT_RUNS:-5}"
N="${N:-150}"; WARMUP="${WARMUP:-40}"; N_POST="${N_POST:-15}"; POST_WARMUP="${POST_WARMUP:-3}"
PORT="${PORT:-3998}"
SWEEP_CONC="${SWEEP_CONC:-1 2 4 8 16}"
SWEEP_DURATION="${SWEEP_DURATION:-3s}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret123456}"
UA="Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"

rv="$(ruby -e 'print RUBY_VERSION')"
case "$rv" in 4.*) ;; *) echo "WARNING: Ruby $rv active; the experiment needs Ruby 4.x (chruby 4.0.1)." >&2 ;; esac

# --- shared cleanup ---
WT="" ; WT_PARENT="" ; SERVER_PID="" ; SAMPLER_PID="" ; TMPFILES=()
cleanup() {
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" >/dev/null 2>&1 || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
  [ -n "$WT" ] && git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  [ -n "$WT_PARENT" ] && rm -rf "$WT_PARENT"
  for f in "${TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done
}
trap cleanup EXIT

# --- shared helpers (server + db) ---
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
boot_server() { # $@ = extra env KEY=VAL ...
  rm -f /tmp/bench_server.log
  ( env "$@" bin/rails server -p "$PORT" -b 127.0.0.1 >/tmp/bench_server.log 2>&1 ) &
  SERVER_PID=$!
  if ! wait_ready; then echo "server did not become ready:" >&2; tail -15 /tmp/bench_server.log >&2; return 1; fi
}
stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  pkill -f "puma.*$PORT" >/dev/null 2>&1 || true
  SERVER_PID=""; sleep 1
}
# Onboard once and echo a Cookie header for the authenticated session.
onboard_cookie() {
  local jar html token; jar="$(mktemp)"; TMPFILES+=("$jar")
  html="$(curl -s -c "$jar" "http://127.0.0.1:$PORT/first_run" -H "User-Agent: $UA")"
  token="$(printf '%s' "$html" | grep -oE 'name="authenticity_token"[^>]*value="[^"]*"' | grep -oE 'value="[^"]*"' | head -1 | sed 's/value="//; s/"$//')"
  curl -s -b "$jar" -c "$jar" -o /dev/null "http://127.0.0.1:$PORT/first_run" -H "User-Agent: $UA" \
    --data-urlencode "authenticity_token=$token" --data-urlencode "user[name]=Bench Admin" \
    --data-urlencode "user[email_address]=$ADMIN_EMAIL" --data-urlencode "user[password]=$ADMIN_PASSWORD"
  # Netscape jar: domain flag path secure expiry name value (HttpOnly lines start "#HttpOnly_").
  awk 'NF>=7 && ($1 !~ /^#/ || $1 ~ /^#HttpOnly_/) {printf "%s=%s; ", $6, $7}' "$jar"
}

# ===========================================================================
# PHASE 1 -- BOOT
# ===========================================================================
phase_boot() {
  echo "########## PHASE 1: BOOT ##########" >&2
  local ref="${BASELINE_REF:-}"
  if [ -z "$ref" ]; then
    local fr; fr="$(git log --reverse --format=%H -- config/initializers/ractor_patches.rb | head -1)"
    [ -n "$fr" ] || { echo "Could not auto-detect baseline; set BASELINE_REF=<sha>." >&2; return 1; }
    ref="$(git rev-parse "${fr}^")"
  fi
  echo "Baseline:   $(git log -1 --format='%h %s' "$ref")" >&2
  echo "Experiment: $(git log -1 --format='%h %s' HEAD)" >&2
  WT_PARENT="$(mktemp -d)"; WT="$WT_PARENT/wb-baseline"
  echo "== Creating baseline worktree ==" >&2
  git worktree add -f "$WT" "$ref" >/dev/null 2>&1
  cp "$APP_DIR/script/boot_delta.rb" "$WT/script/boot_delta.rb"
  local prod="$WT/config/environments/production.rb"
  if grep -q 'config.cache_store' "$prod"; then
    sed -i.bak 's/^\( *\)config\.cache_store = .*/\1config.cache_store = :null_store/' "$prod"; rm -f "$prod.bak"
  fi
  echo "== bundle install (baseline) -- may take a minute ==" >&2
  if ! ( cd "$WT" && bundle install ) >/dev/null 2>&1; then
    echo "baseline bundle install failed:" >&2; ( cd "$WT" && bundle install ) 2>&1 | tail -15; return 1
  fi
  local base_out exp_out; base_out="$(mktemp)"; exp_out="$(mktemp)"; TMPFILES+=("$base_out" "$exp_out")
  local dir rest label out i line
  for pair in "$WT:baseline:$base_out" "$APP_DIR:experiment:$exp_out"; do
    dir="${pair%%:*}"; rest="${pair#*:}"; label="${rest%%:*}"; out="${rest#*:}"; : > "$out"
    echo "== Booting $label x$BOOT_RUNS ==" >&2
    for i in $(seq 1 "$BOOT_RUNS"); do
      if line="$(cd "$dir" && ruby script/boot_delta.rb 2>/dev/null | grep '^BOOTDELTA')"; then echo "$line" >> "$out"; fi
      echo "  $label run $i/$BOOT_RUNS" >&2
    done
  done
  echo >&2
  ruby - "$base_out" "$exp_out" <<'RUBY'
base = File.readlines(ARGV[0]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
exp  = File.readlines(ARGV[1]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
abort "no successful boot runs" if base.empty? || exp.empty?
def med(xs) = (s = xs.sort; s.size.odd? ? s[s.size/2] : (s[s.size/2-1]+s[s.size/2])/2.0)
def col(r,i) = r.map { |x| x[i] }
b_boot=med(col(base,0)); b_rss=med(col(base,6)); e_boot=med(col(exp,0)); e_rss=med(col(exp,6))
e_full=med(exp.map{|r|r[0]+r[2]}); e_rss2=med(col(exp,7))
e_rz=med(col(exp,2)); e_bf=med(col(exp,3)); e_gf=med(col(exp,4)); e_on=med(col(exp,5))
printf("Boot comparison (median of %d boots/side, production)\n\n", [base.size,exp.size].min)
printf("%-42s %10s %10s\n%-42s %10s %10s\n", "", "boot ms", "RSS MB", "-"*42, "-"*10, "-"*10)
printf("%-42s %10.1f %10.1f\n", "baseline (main, no Ractor code)", b_boot, b_rss)
printf("%-42s %10.1f %10.1f\n", "experiment, base only (no ractorize!)", e_boot, e_rss)
printf("%-42s %10.1f %10.1f\n\n", "experiment, full (+ ractorize!)", e_full, e_rss2)
printf("Our code's effect on base boot : %+.1f ms (%+.1f%%), RSS %+.1f MB\n", e_boot-b_boot, (e_boot-b_boot)/b_boot*100, e_rss-b_rss)
printf("ractorize! delta (server-only) : %+.1f ms (%+.1f%%), RSS %+.1f MB\n", e_rz, e_rz/e_boot*100, e_rss2-e_rss)
printf("  before_freeze / graph_freeze / on_freeze: %.1f / %.1f / %.1f ms\n", e_bf, e_gf, e_on)
RUBY
  git worktree remove --force "$WT" >/dev/null 2>&1 || true; git worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT_PARENT"; WT=""; WT_PARENT=""
}

# ===========================================================================
# PHASE 2 -- LATENCY (concurrency 1)
# ===========================================================================
phase_latency() {
  echo >&2; echo "########## PHASE 2: LATENCY (concurrency 1) ##########" >&2
  export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1
  local out; out="$(mktemp)"; TMPFILES+=("$out")
  local label envv
  for pair in "base:RACTOR_MODE=0" "ractor:RACTOR_METRICS=1"; do
    label="${pair%%:*}"; envv="${pair#*:}"
    echo "== [$label] reset + boot ==" >&2
    reset_db; boot_server "$envv"
    echo "== [$label] probing (N=$N warmup=$WARMUP N_POST=$N_POST) ==" >&2
    MODE="$label" PORT="$PORT" N="$N" WARMUP="$WARMUP" N_POST="$N_POST" POST_WARMUP="$POST_WARMUP" \
      ruby script/latency_probe.rb >> "$out"
    stop_server
  done
  echo >&2
  ruby - "$out" <<'RUBY'
rows = File.readlines(ARGV[0]).map { |l| l.strip.split(",") }.select { |r| r[0] == "LAT" }
by = Hash.new { |h,k| h[k] = {} }; rows.each { |r| by[r[2]][r[1]] = r }
order = ["/up", "/first_run", "POST /first_run", "/"]
puts "Concurrency-1 latency: base (no Ractor) vs ractor  [client-side ms]\n\n"
printf("%-16s %-7s %8s %8s %8s %8s %9s %9s %9s  %s\n%s\n", "endpoint","mode","p50","p90","p99","max","disp","main","worker","n","-"*92)
order.each do |ep|
  next unless by.key?(ep)
  %w[base ractor].each do |m|
    r = by[ep][m] or next
    d = m=="ractor" ? r[12] : "-"; mn = m=="ractor" ? r[10] : "-"; w = m=="ractor" ? r[11] : "-"
    printf("%-16s %-7s %8s %8s %8s %8s %9s %9s %9s  %s\n", ep, m, r[4], r[5], r[6], r[7], d, mn, w, r[3])
  end
  b=by[ep]["base"]; x=by[ep]["ractor"]
  if b && x && b[4].to_f>0
    dd=x[4].to_f-b[4].to_f
    printf("%-16s %-7s p50 %+.2f ms (%+.1f%%)\n", "", "delta", dd, dd/b[4].to_f*100)
  end
  puts
end
RUBY
}

# ===========================================================================
# PHASE 3 -- SWEEP (throughput vs concurrency)
# ===========================================================================
phase_sweep() {
  echo >&2; echo "########## PHASE 3: SWEEP (throughput vs concurrency) ##########" >&2
  command -v oha >/dev/null || { echo "oha not found; skipping sweep (brew install oha)." >&2; return 0; }
  export RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1
  local maxc; maxc="$(printf '%s\n' $SWEEP_CONC | sort -n | tail -1)"
  local threads=$(( maxc > 8 ? maxc : 8 ))
  local out; out="$(mktemp)"; TMPFILES+=("$out")

  parse_oha() { # json on stdin -> "rps,p50ms,p99ms,success,total"
    ruby -rjson -e 'j=JSON.parse(STDIN.read); s=j["summary"]; p=j["latencyPercentiles"];
      printf("%.0f,%.2f,%.2f,%.3f,%d", s["requestsPerSec"], (p["p50"]||0)*1000, (p["p99"]||0)*1000, s["successRate"], s["total"])' 2>/dev/null || echo "0,0,0,0,0"
  }

  local label envv cookie rss_out ep eppath epck c json stats peak
  for pair in "base:RACTOR_MODE=0" "ractor:RACTOR_METRICS=1"; do
    label="${pair%%:*}"; envv="${pair#*:}"
    echo "== [$label] reset + boot (RAILS_MAX_THREADS=$threads) ==" >&2
    reset_db; boot_server "$envv" "RAILS_MAX_THREADS=$threads"
    echo "== [$label] onboarding (POST /first_run) ==" >&2
    cookie="$(onboard_cookie)"

    # peak-RSS sampler over this mode's whole sweep
    rss_out="$(mktemp)"; TMPFILES+=("$rss_out")
    ( while kill -0 "$SERVER_PID" 2>/dev/null; do ps -o rss= -p "$SERVER_PID" 2>/dev/null | tr -d ' '; sleep 0.2; done >> "$rss_out" ) &
    SAMPLER_PID=$!

    for eppair in "/up:" "/:$cookie"; do
      eppath="${eppair%%:*}"; epck="${eppair#*:}"
      # warmup
      oha --no-tui --output-format quiet -c 4 -z 1s -H "User-Agent: $UA" ${epck:+-H "Cookie: $epck"} "http://127.0.0.1:$PORT$eppath" >/dev/null 2>&1 || true
      for c in $SWEEP_CONC; do
        echo "  [$label] $eppath c=$c" >&2
        json="$(oha --no-tui --output-format json -c "$c" -z "$SWEEP_DURATION" -H "User-Agent: $UA" ${epck:+-H "Cookie: $epck"} "http://127.0.0.1:$PORT$eppath" 2>/dev/null)"
        stats="$(printf '%s' "$json" | parse_oha)"
        echo "SWEEP,$label,$eppath,$c,$stats" >> "$out"
      done
    done

    kill "$SAMPLER_PID" >/dev/null 2>&1 || true; SAMPLER_PID=""
    peak="$(sort -n "$rss_out" 2>/dev/null | tail -1)"; peak="${peak:-0}"
    echo "SWEEPRSS,$label,$(ruby -e "printf('%.1f', ${peak}/1024.0)")" >> "$out"
    stop_server
  done
  echo >&2

  ruby - "$out" <<'RUBY'
lines = File.readlines(ARGV[0]).map { |l| l.strip.split(",") }
sw  = lines.select { |r| r[0]=="SWEEP" }     # SWEEP,mode,path,conc,rps,p50,p99,success,total
rss = lines.select { |r| r[0]=="SWEEPRSS" }.to_h { |r| [r[1], r[2]] }
by = Hash.new { |h,k| h[k]={} }              # by[path][conc][mode] = row
sw.each { |r| (by[r[2]][r[3].to_i] ||= {})[r[1]] = r }

puts "Throughput & latency vs concurrency  (oha, #{sw.first ? "duration each" : ""})"
by.keys.each do |path|
  label = path == "/" ? "/ (authenticated)" : path
  puts
  puts "endpoint: #{label}"
  printf("%5s | %9s %9s %7s | %8s %8s | %8s %8s | %s\n",
         "conc", "base rps", "ractor", "r/b", "base p50", "ractor", "base p99", "ractor", "success")
  printf("%s\n", "-"*84)
  by[path].keys.sort.each do |c|
    b = by[path][c]["base"]; x = by[path][c]["ractor"]
    bok = b && b[7].to_f >= 0.999; xok = x && x[7].to_f >= 0.999
    # Rows with low success are errors/crashes -- their "rps" is an error flood,
    # so show the failure instead of a bogus throughput/speedup.
    bcell = b ? (bok ? sprintf("%.0f", b[4].to_f) : sprintf("ERR%.0f%%", b[7].to_f*100)) : "-"
    xcell = x ? (xok ? sprintf("%.0f", x[4].to_f) : sprintf("ERR%.0f%%", x[7].to_f*100)) : "-"
    rb    = (bok && xok && b[4].to_f > 0) ? sprintf("%.2fx", x[4].to_f/b[4].to_f) : "-"
    bp50  = bok ? sprintf("%.2f", b[5].to_f) : "-"; xp50 = xok ? sprintf("%.2f", x[5].to_f) : "-"
    bp99  = bok ? sprintf("%.2f", b[6].to_f) : "-"; xp99 = xok ? sprintf("%.2f", x[6].to_f) : "-"
    printf("%5d | %9s %9s %7s | %8s %8s | %8s %8s |\n", c, bcell, xcell, rb, bp50, xp50, bp99, xp99)
  end
end
puts
puts "Peak RSS under load:  base #{rss["base"]} MB   ractor #{rss["ractor"]} MB"
puts
puts "Notes: RAILS_MAX_THREADS sized to max concurrency (both modes). base = normal"
puts "Rails on the main Ractor (GVL-bound across threads); ractor = per-request worker"
puts "Ractors (parallel) that funnel DB through the single main-dispatch thread."
puts "'r/b' = ractor throughput / base throughput. p50/p99 in ms."
RUBY
}

[ "${SKIP_BOOT:-}"    = "1" ] || phase_boot
[ "${SKIP_LATENCY:-}" = "1" ] || phase_latency
[ "${SKIP_SWEEP:-}"   = "1" ] || phase_sweep
