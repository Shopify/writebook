# frozen_string_literal: true
#
# Measures application boot timing, split into:
#
#   base_boot     - require "config/environment" (Rails boot + eager load).
#                   This is what a NON-Ractor production boot pays.
#   load_server   - Rails.application.load_server (rack setup).
#   ractorize     - the extra cost of Rails.application.ractorize!, split into:
#       before_freeze  - warming lazily-memoized state (ActiveSupport::Ractors
#                        before_freeze callbacks).
#       graph_freeze   - Ractor.make_shareable(self) deep-freezing the whole
#                        application object graph (+ a few trailing shares).
#                        Derived as ractorize - before_freeze - on_freeze.
#       on_freeze      - freezing/sharing remaining request-path state
#                        (on_freeze callbacks).
#
# Ractor boot delta = the whole `ractorize` bucket (it's pure additive cost;
# base_boot / load_server are identical in both modes).
#
# One boot per process (ractorize! freezes irreversibly). Use
# script/boot_delta.sh to aggregate over N fresh processes.
#
# Emits one machine-readable line:
#   BOOTDELTA,<base>,<load_server>,<ractorize>,<before>,<graph>,<on>,<rss_base>,<rss_after>
# (times in ms, RSS in MB)

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def rss_mb = (`ps -o rss= -p #{Process.pid}`.to_i / 1024.0)

ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"
ENV["DISABLE_SSL"] ||= "1"

# --- base boot (what non-Ractor production pays) ---
t = now
require_relative "../config/environment"
base_boot = now - t

t = now
Rails.application.load_server
load_server = now - t

rss_base = rss_mb

# --- instrument the two wrappable ractorize! phases ---
require "active_support/ractors"

$rz = {}
module RactorizeTiming
  def run_before_freeze!
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
    $rz[:before_freeze] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end

  def run_on_freeze!
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
    $rz[:on_freeze] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
end
ActiveSupport::Ractors.singleton_class.prepend(RactorizeTiming)

# --- ractorize! (the Ractor boot delta) ---
t = now
Rails.application.ractorize! unless Rails.application.frozen?
ractorize = now - t

rss_after = rss_mb

before = $rz[:before_freeze] || 0.0
on     = $rz[:on_freeze] || 0.0
graph  = ractorize - before - on # dominated by Ractor.make_shareable(self)

row = [base_boot, load_server, ractorize, before, graph, on].map { |s| (s * 1000).round(1) }
row += [rss_base.round(1), rss_after.round(1)]
puts "BOOTDELTA,#{row.join(",")}"
