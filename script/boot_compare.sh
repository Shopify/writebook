#!/usr/bin/env bash
#
# Boot-time comparison: the pre-Ractor "main" baseline vs the current Ractor
# experiment. Does everything end to end:
#
#   1. auto-detects the last commit BEFORE any Ractor code (parent of the commit
#      that introduced config/initializers/ractor_patches.rb) -- override with
#      BASELINE_REF=<sha>.
#   2. creates a throwaway git worktree at that commit,
#   3. normalizes its cache store to :null_store (the baseline shipped with
#      :redis_cache_store, which the experiment also replaced -- so the only
#      variable left is the Ractor work),
#   4. bundle installs it,
#   5. boots each side N times (fresh process per boot) via script/boot_delta.rb,
#   6. prints a three-way comparison, and
#   7. removes the worktree.
#
# Usage:   script/boot_compare.sh [N]        # N boots per side, default 5
# Requires Ruby 4.x active (chruby 4.0.1) -- same as the experiment.
set -euo pipefail

N="${1:-5}"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

rv="$(ruby -e 'print RUBY_VERSION')"
case "$rv" in
  4.*) ;;
  *) echo "WARNING: Ruby $rv is active but the experiment needs Ruby 4.x (chruby 4.0.1)." >&2 ;;
esac

# 1. Baseline ref = parent of the first commit that added the Ractor initializer.
if [ -z "${BASELINE_REF:-}" ]; then
  first_ractor="$(git log --reverse --format=%H -- config/initializers/ractor_patches.rb | head -1)"
  [ -n "$first_ractor" ] || { echo "Could not auto-detect baseline; set BASELINE_REF=<sha>." >&2; exit 1; }
  BASELINE_REF="$(git rev-parse "${first_ractor}^")"
fi
echo "Baseline: $(git log -1 --format='%h %s' "$BASELINE_REF")" >&2
echo "Experiment: $(git log -1 --format='%h %s' HEAD)" >&2
echo >&2

# 2. Throwaway worktree at the baseline commit.
WT_PARENT="$(mktemp -d)"
WT="$WT_PARENT/wb-baseline"
cleanup() {
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT_PARENT"
}
trap cleanup EXIT

echo "== Creating baseline worktree ==" >&2
git worktree add -f "$WT" "$BASELINE_REF" >/dev/null 2>&1

# Use the current (adaptive) boot timer inside the baseline checkout.
cp "$APP_DIR/script/boot_delta.rb" "$WT/script/boot_delta.rb"

# 3. Normalize the cache store so Redis isn't a confound.
prod="$WT/config/environments/production.rb"
if grep -q 'config.cache_store' "$prod"; then
  sed -i.bak 's/^\( *\)config\.cache_store = .*/\1config.cache_store = :null_store/' "$prod"
  rm -f "$prod.bak"
fi

# 4. Install the baseline's own gem set.
echo "== bundle install (baseline) -- may take a minute ==" >&2
if ! ( cd "$WT" && bundle install ) >/dev/null 2>&1; then
  echo "baseline bundle install failed:" >&2
  ( cd "$WT" && bundle install ) 2>&1 | tail -15
  exit 1
fi

run_n() { # $1 = dir, $2 = output file
  : > "$2"
  for i in $(seq 1 "$N"); do
    if out="$(cd "$1" && ruby script/boot_delta.rb 2>/dev/null | grep '^BOOTDELTA')"; then
      echo "$out" >> "$2"
    else
      echo "  ($1) run $i failed" >&2
    fi
    echo "  $(basename "$1") run $i/$N" >&2
  done
}

BASE_OUT="$(mktemp)"; EXP_OUT="$(mktemp)"
trap 'cleanup; rm -f "$BASE_OUT" "$EXP_OUT"' EXIT

echo "== Booting baseline x$N ==" >&2
run_n "$WT" "$BASE_OUT"
echo "== Booting experiment x$N ==" >&2
run_n "$APP_DIR" "$EXP_OUT"
echo >&2

# 6. Aggregate + compare.
ruby - "$BASE_OUT" "$EXP_OUT" <<'RUBY'
base = File.readlines(ARGV[0]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
exp  = File.readlines(ARGV[1]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
abort "no successful runs" if base.empty? || exp.empty?

def med(xs)
  s = xs.sort
  s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
end
# columns: 0 base_boot 1 load_server 2 ractorize 3 before 4 graph 5 on 6 rss_base 7 rss_after
def col(rows, i) = rows.map { |r| r[i] }

b_boot = med(col(base, 0));                 b_rss = med(col(base, 6))
e_boot = med(col(exp, 0));                  e_rss = med(col(exp, 6))
e_full = med(exp.map { |r| r[0] + r[2] });  e_rss2 = med(col(exp, 7))
e_rz   = med(col(exp, 2)); e_bf = med(col(exp, 3)); e_gf = med(col(exp, 4)); e_on = med(col(exp, 5))

n = [base.size, exp.size].min
puts
printf("Boot comparison (median of %d boots/side, production)\n\n", n)
printf("%-42s %10s %10s\n", "", "boot ms", "RSS MB")
printf("%-42s %10s %10s\n", "-"*42, "-"*10, "-"*10)
printf("%-42s %10.1f %10.1f\n", "baseline (main, no Ractor code)", b_boot, b_rss)
printf("%-42s %10.1f %10.1f\n", "experiment, base only (no ractorize!)", e_boot, e_rss)
printf("%-42s %10.1f %10.1f\n", "experiment, full (+ ractorize!)", e_full, e_rss2)
puts
printf("Our code's effect on base boot : %+.1f ms (%+.1f%%), RSS %+.1f MB\n",
       e_boot - b_boot, (e_boot - b_boot) / b_boot * 100, e_rss - b_rss)
printf("ractorize! delta (server-only) : %+.1f ms (%+.1f%%), RSS %+.1f MB\n",
       e_rz, e_rz / e_boot * 100, e_rss2 - e_rss)
printf("  before_freeze (warming)      : %8.1f ms\n", e_bf)
printf("  graph_freeze (make_shareable): %8.1f ms\n", e_gf)
printf("  on_freeze                    : %8.1f ms\n", e_on)
puts
puts "Caveat: baseline & experiment lockfiles differ slightly (Rails main commit +"
puts "other gem versions), so small base-boot deltas are within noise/version drift."
RUBY
