# Throughput of the real Rails app across N Ractors -- no web server, no FFI,
# no queue. Each Ractor calls the shared, frozen Rails.application.call(env) in
# a tight loop with a dummy Rack env for GET /up, for DUR seconds. Prints the
# aggregate rps and per-worker rps so you can see whether adding Ractors scales
# throughput up or collapses it.
#
# This is the isolation harness that pinned the multi-Ractor throughput
# collapse on YJIT: with YJIT on, rps peaks at N=1 then collapses as workers
# grow (YJIT's rb_jit_vm_lock_then_barrier takes the global VM lock + a
# stop-the-world Ractor barrier for lazy compilation/invalidation, pausing all
# workers); with YJIT off (NO_YJIT=1) the same app scales like a Puma cluster.
#
# Pair it with script/ractor_trivial_bench.rb (a trivial shared Rack proc in
# the identical harness) -- that one scales regardless of YJIT because it has
# almost no code for YJIT to compile, proving the cost is YJIT's code
# management under Ractors, not the act of sharing a frozen callable.
#
# Run (needs the app booted, so via `bin/rails runner`):
#   RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DISABLE_SSL=1 \
#     N=8 DUR=3 bin/rails runner script/ractor_appcall_bench.rb
#
# Env:
#   N        worker Ractors (default 1)
#   DUR      seconds to run (default 3)
#   NOGC=1   GC.disable (rules GC in/out)
#   NOLOG=1  raise the logger level so requests don't log (rules the logger out)
#   NO_YJIT=1  disable YJIT (via the config.yjit guard in production.rb)
#   PROFILE=1  profile the whole process with macOS `sample` during the run
#              (writes tmp/ractor_appcall_sample.txt, override with SAMPLE_OUT)
#              and prints the YJIT / Ractor-barrier frame signature.
#
# Capture a profile of the collapse (run with several workers):
#   N=8 DUR=8 PROFILE=1 bin/rails runner script/ractor_appcall_bench.rb
# Then inspect the frames that request the stop-the-world barrier, e.g.:
#   grep -c rb_jit_vm_lock_then_barrier tmp/ractor_appcall_sample.txt
#
# Sweep both YJIT modes:
#   for n in 1 2 4 8; do N=$n DUR=3 bin/rails runner script/ractor_appcall_bench.rb; done
#   for n in 1 2 4 8; do N=$n DUR=3 NO_YJIT=1 bin/rails runner script/ractor_appcall_bench.rb; done

require "stringio"

Rails.application.load_server

if ENV["NOLOG"] == "1"
  require "logger"
  Rails.logger.level = Logger::ERROR
  warn "[nolog] logger level=#{Rails.logger.level}"
end
warn "[yjit] enabled=#{(RubyVM::YJIT.enabled? rescue :na)}"

Rails.application.ractorize! unless Rails.application.frozen?
require "ractor/dispatch"
Ractor::Dispatch.main

APP = Rails.application
N   = Integer(ENV["N"] || "1")
DUR = Float(ENV["DUR"] || "3")
GC.disable if ENV["NOGC"] == "1"
gc0 = GC.stat(:count)

# A fresh dummy Rack env for GET /up, built inside each Ractor per request so
# nothing mutable is shared between workers.
ENVBUILD = Ractor.shareable_proc do
  { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up", "SCRIPT_NAME" => "", "QUERY_STRING" => "",
    "SERVER_NAME" => "127.0.0.1", "SERVER_PORT" => "3000", "HTTP_HOST" => "127.0.0.1",
    "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new(+""),
    "rack.url_scheme" => "http", "HTTP_USER_AGENT" => "probe" }
end

# Sanity: /up returns 200 on the main Ractor before we fan out.
st0, _h0, body0 = APP.call(ENVBUILD.call)
body0.close if body0.respond_to?(:close)
warn "sanity /up on main -> status=#{st0}"

# Optional: profile the whole process with macOS `sample` for the duration of
# the run (captures every worker Ractor's native stacks).
sampler = nil
sample_out = ENV["SAMPLE_OUT"] || File.expand_path("../tmp/ractor_appcall_sample.txt", __dir__)
if ENV["PROFILE"] == "1"
  if system("which sample >/dev/null 2>&1")
    require "fileutils"
    FileUtils.mkdir_p(File.dirname(sample_out))
    secs = [DUR.ceil, 1].max
    sampler = spawn("sample", Process.pid.to_s, secs.to_s, "-file", sample_out, %i[out err] => File::NULL)
    warn "[profile] sampling pid=#{Process.pid} for #{secs}s -> #{sample_out}"
  else
    warn "[profile] macOS `sample` not found; skipping profile"
  end
end

done = Ractor::Port.new
N.times do
  Ractor.new(APP, DUR, done) do |app, dur, done|
    # Each worker Ractor gets its own (empty) connection handler; /up hits no DB.
    ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + dur
    n = 0
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      _status, _h, body = app.call(ENVBUILD.call)
      body.close if body.respond_to?(:close)
      n += 1
    end
    done << n
  end
end

total = 0
N.times { total += done.receive }
printf("N=%d nogc=%s  rps=%.0f  per-worker=%.0f  gc_runs=%d\n",
       N, ENV["NOGC"] || "0", total / DUR, total.to_f / DUR / N, GC.stat(:count) - gc0)

if sampler
  Process.wait(sampler)
  if File.exist?(sample_out)
    txt = File.read(sample_out)
    warn "[profile] wrote #{sample_out} (#{File.size(sample_out)} bytes)"
    warn "[profile] YJIT / Ractor-barrier signature (occurrences in the profile):"
    %w[rb_jit_vm_lock_then_barrier rb_ractor_sched_barrier_join vm_lock_enter
       __psynch_cvwait __psynch_mutexwait].each do |sym|
      warn format("[profile]   %-32s %d", sym, txt.scan(sym).size)
    end
  else
    warn "[profile] sample produced no output"
  end
end
