# Control for script/ractor_appcall_bench.rb: the SAME N-Ractor harness and the
# SAME dummy-env allocation profile, but the app is a trivial shared frozen Rack
# proc that returns [200, {...}, ["ok"]] and does essentially no work. Each
# Ractor calls it in a tight loop for DUR seconds; prints aggregate + per-worker
# rps.
#
# Why it matters: this control SCALES with worker count (throughput rises) even
# with YJIT on, whereas the real Rails app in the identical harness COLLAPSES
# with YJIT on. Since the only difference is how much code the callable runs,
# this isolates the multi-Ractor throughput collapse to YJIT's code management
# (rb_jit_vm_lock_then_barrier -> global VM lock + stop-the-world Ractor
# barrier), not to the act of sharing a frozen callable, the env allocation, GC,
# or the queue/FFI. A trivial callable gives YJIT almost nothing to compile or
# invalidate, so no barrier storm.
#
# No Rails, no web server -- run with plain ruby (needs a Ractor-capable Ruby):
#   N=8 DUR=3 ruby script/ractor_trivial_bench.rb
#
# Env:
#   N        worker Ractors (default 1)
#   DUR      seconds to run (default 3)
#   NOGC=1   GC.disable
#   YJIT=1   enable YJIT (plain ruby starts with it off; there is no runtime
#            disable, so leave it unset for the YJIT-off run)
#
# Sweep both YJIT modes (this control scales in BOTH -- unlike the Rails app):
#   for n in 1 2 4 8; do N=$n DUR=3          ruby script/ractor_trivial_bench.rb; done
#   for n in 1 2 4 8; do N=$n DUR=3 YJIT=1   ruby script/ractor_trivial_bench.rb; done

require "stringio"

RubyVM::YJIT.enable if ENV["YJIT"] == "1" && defined?(RubyVM::YJIT.enable)
warn "[yjit] enabled=#{(RubyVM::YJIT.enabled? rescue :na)}"

N   = Integer(ENV["N"] || "1")
DUR = Float(ENV["DUR"] || "3")
GC.disable if ENV["NOGC"] == "1"
gc0 = GC.stat(:count)

# Trivial shared frozen Rack app: same call shape as Rails.application, ~no work.
APP = Ractor.shareable_proc { |_env| [200, { "content-type" => "text/plain" }, ["ok"]] }

# Identical env building to the Rails harness (same per-request allocation).
ENVBUILD = Ractor.shareable_proc do
  { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "", "QUERY_STRING" => "",
    "SERVER_NAME" => "127.0.0.1", "SERVER_PORT" => "3000", "HTTP_HOST" => "127.0.0.1",
    "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new(+""),
    "rack.url_scheme" => "http", "HTTP_USER_AGENT" => "probe" }
end

done = Ractor::Port.new
N.times do
  Ractor.new(APP, DUR, done) do |app, dur, done|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + dur
    n = 0
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      _status, _h, _body = app.call(ENVBUILD.call)
      n += 1
    end
    done << n
  end
end

total = 0
N.times { total += done.receive }
printf("N=%d nogc=%s  rps=%.0f  per-worker=%.0f  gc_runs=%d\n",
       N, ENV["NOGC"] || "0", total / DUR, total.to_f / DUR / N, GC.stat(:count) - gc0)
