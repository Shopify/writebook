#!/usr/bin/env bash
# Aggregate boot-timing over N fresh processes (default 5).
#
#   script/boot_delta.sh [N]
#
# Each run boots the app once (base boot + ractorize!) and prints a BOOTDELTA
# line; we collect them and report min / median / max per phase so a single
# slow/fast outlier doesn't dominate.
set -euo pipefail

N="${1:-5}"
cd "$(dirname "$0")/.."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "Booting $N times (RAILS_ENV=production)..." >&2
for i in $(seq 1 "$N"); do
  echo "  run $i/$N" >&2
  # Fresh process each time; keep only the BOOTDELTA line.
  ruby script/boot_delta.rb 2>/dev/null | grep '^BOOTDELTA' >> "$TMP" || {
    echo "  run $i failed" >&2; }
done

echo >&2
ruby - "$TMP" <<'RUBY'
rows = File.readlines(ARGV[0]).map { |l| l.strip.split(",")[1..].map(&:to_f) }
abort "no successful runs" if rows.empty?

labels = [
  ["base_boot (non-Ractor boot)", "ms"],
  ["load_server",                 "ms"],
  ["ractorize! TOTAL (delta)",    "ms"],
  ["  before_freeze (warming)",   "ms"],
  ["  graph_freeze (make_shareable)", "ms"],
  ["  on_freeze",                 "ms"],
  ["RSS after base boot",         "MB"],
  ["RSS after ractorize!",        "MB"],
]

def stats(xs)
  s = xs.sort
  med = s.size.odd? ? s[s.size/2] : (s[s.size/2 - 1] + s[s.size/2]) / 2.0
  [s.first, med, s.last]
end

n = rows.size
printf("%-34s %10s %10s %10s\n", "metric (#{n} runs)", "min", "median", "max")
printf("%-34s %10s %10s %10s\n", "-"*34, "-"*10, "-"*10, "-"*10)
labels.each_with_index do |(label, unit), i|
  mn, md, mx = stats(rows.map { |r| r[i] })
  printf("%-34s %10.1f %10.1f %10.1f  %s\n", label, mn, md, mx, unit)
end

base   = stats(rows.map { |r| r[0] })[1]
rz     = stats(rows.map { |r| r[2] })[1]
puts
printf("Boot delta (median): base %.1f ms -> +ractorize %.1f ms = %.1f ms total (+%.0f%%)\n",
       base, rz, base + rz, (rz / base) * 100)
RUBY
