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
# Run with plain `ruby` -- the script sets the production flags and boots Rails
# itself, so no `bin/rails runner` and no exported env are needed:
#   N=8 DUR=3 ruby script/ractor_appcall_bench.rb
#
# Env:
#   N        worker Ractors (default 1)
#   DUR      seconds to run (default 3)
#   NOGC=1   GC.disable (rules GC in/out)
#   WARM=K   run K warmup requests on the main Ractor before fanning out, to
#            fully warm YJIT's lazy compilation (tells one-time compile cost
#            apart from a persistent per-request barrier)
#   LOG=1    show per-request logs (silenced by default; the logger was
#            measured NOT to be the bottleneck)
#   NO_YJIT=1  disable YJIT (via the config.yjit guard in production.rb)
#   PROFILE=1  profile the whole process with macOS `sample` during the run
#              (writes tmp/ractor_appcall_sample.txt, override with SAMPLE_OUT)
#              and prints the YJIT / Ractor-barrier frame signature.
#   STATS=1    enable YJIT stats, warm up on the main Ractor, reset the
#              counters, then report which YJIT mechanism fires during the
#              N-Ractor load (compilation vs invalidation vs the multi-Ractor
#              constant-cache de-opt). Forces YJIT on.
#
# Capture a profile of the collapse (run with several workers):
#   N=8 DUR=8 PROFILE=1 ruby script/ractor_appcall_bench.rb
# Then inspect the frames that request the stop-the-world barrier, e.g.:
#   grep -c rb_jit_vm_lock_then_barrier tmp/ractor_appcall_sample.txt
#
# Sweep both YJIT modes:
#   for n in 1 2 4 8; do N=$n DUR=3          ruby script/ractor_appcall_bench.rb; done
#   for n in 1 2 4 8; do N=$n DUR=3 NO_YJIT=1 ruby script/ractor_appcall_bench.rb; done

# STATS=1: turn YJIT stats on *before* anything compiles (we reset the counters
# after warmup, so what we report is purely the steady-state N-Ractor load).
RubyVM::YJIT.enable(stats: true) if ENV["STATS"] == "1" && defined?(RubyVM::YJIT.enable)

# Set the flags this benchmark needs *before* booting Rails (respecting any the
# caller already set), then boot the app ourselves. config/environment pulls in
# Bundler + initializes the app, so plain `ruby script/...` works -- unless the
# app is already booted (e.g. run under `bin/rails runner`), in which case we
# skip the boot and use whatever environment is already loaded.
unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.initialized?
  ENV["RAILS_ENV"]             ||= "production"
  ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"
  ENV["DISABLE_SSL"]           ||= "1"
  require_relative "../config/environment"
end

require "stringio"

Rails.application.load_server

# Silence per-request logging by default -- it floods stdout and was measured
# NOT to be the bottleneck. Set LOG=1 to see the request logs.
require "logger"
Rails.logger.level = Logger::FATAL unless ENV["LOG"] == "1"
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

# WARM: pre-run this many requests on the main Ractor to fully warm YJIT's
# lazy compilation before fanning out. If the N-Ractor collapse is just
# cold-start branch/entry-stub compilation (each stub hit takes YJIT's
# with_vm_lock -> stop-the-world barrier), warming should remove it; if it
# persists, the barrier is triggered per request in steady state. STATS
# implies a warmup so its counters reflect only steady state.
warm = (ENV["WARM"] || (ENV["STATS"] == "1" ? "2000" : "0")).to_i
if warm > 0
  warm.times { _s, _h, b = APP.call(ENVBUILD.call); b.close if b.respond_to?(:close) }
  warn "[warm] #{warm} warmup requests on the main Ractor"
end
if ENV["STATS"] == "1" && (RubyVM::YJIT.enabled? rescue false)
  RubyVM::YJIT.reset_stats!
  warn "[stats] YJIT counters reset -- now measuring the #{N}-Ractor load"
end

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

if ENV["STATS"] == "1" && (s = (RubyVM::YJIT.runtime_stats rescue nil))
  # After a full main-Ractor warmup + reset, these counters are triggered ONLY
  # by running the already-compiled code across N Ractors. Watch for:
  #  - compiled_* / compile_time_ns : ongoing (re)compilation under Ractors
  #  - invalidate_* / invalidation_count : code being thrown away (each = barrier)
  #  - opt_getconstant_path_multi_ractor : YJIT can't use its constant inline
  #    cache with >1 Ractor, so constant reads fall back to the VM-locked path
  keys = %w[
    compiled_iseq_count compiled_block_count compiled_branch_count compile_time_ns
    code_gc_count freed_iseq_count invalidation_count
    invalidate_constant_state_bump invalidate_constant_ic_fill invalidate_method_lookup
    invalidate_ep_escape invalidate_bop_redefined invalidate_ractor_spawn invalidate_everything
    opt_getconstant_path_multi_ractor opt_getconstant_path_ic_miss
    side_exit_count total_exit_count
  ]
  warn "[stats] YJIT activity during the #{N}-Ractor load (#{total} requests, #{format('%.0f', total / DUR)} rps):"
  keys.each do |k|
    v = s[k]
    next if v.nil? || v == 0
    warn format("[stats]   %-34s %14d  (%.2f/req)", k, v, v.to_f / total)
  end
end
