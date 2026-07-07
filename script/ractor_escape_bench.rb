# Minimal, pure-Ruby root-cause reproducer for the multi-Ractor + YJIT
# throughput collapse (no Rails, no web server). It narrows the collapse that
# ractor_appcall_bench.rb shows for the full Rails app down to a single
# trigger: materializing a frame's environment (creating a closure/binding)
# while YJIT is on.
#
# WHY: when a Ruby frame's environment escapes to the heap (e.g. you create a
# Proc/lambda that captures a local, or call `binding`), the VM calls
# rb_yjit_invalidate_ep_is_bp(iseq) (vm.c). That function takes YJIT's
# with_vm_lock -- a *stop-the-world Ractor barrier* -- on EVERY call. It only
# has anything to invalidate the first time per ISEQ; after that the barrier is
# pure overhead (which is why RubyVM::YJIT.runtime_stats shows invalidate_ep_escape
# == 0 in steady state even though the barrier keeps firing). With N Ractors
# each escaping an environment per iteration, they spend all their time in
# rb_ractor_sched_barrier_join and throughput collapses as N grows.
#
# Two workloads, identical except for one line:
#   escape   : `f = -> { a }`  -- capturing lambda => env materialized => barrier
#   noescape : `(a + 1)`       -- no capture => no materialization => no barrier
#
# Expected (this machine, N=1 -> N=8):
#   YJIT on   escape   : ~5.5M  -> ~37K    ops/s   (~150x COLLAPSE)
#   YJIT on   noescape : ~20M   -> ~120M   ops/s   (~6x scale-up)
#   YJIT off  escape   : ~6M    -> ~9M     ops/s   (no collapse)
#
# Run (plain ruby; YJIT is off by default here, enable with YJIT=1):
#   WORKLOAD=escape   YJIT=1 N=8 ruby script/ractor_escape_bench.rb
#   WORKLOAD=noescape YJIT=1 N=8 ruby script/ractor_escape_bench.rb
#
# Full 2x2:
#   for wl in escape noescape; do for n in 1 8; do
#     WORKLOAD=$wl YJIT=1 N=$n ruby script/ractor_escape_bench.rb; done; done
#
# Env:  N (workers, default 1)  DUR (seconds, default 3)  YJIT=1 (enable YJIT)
#       WORKLOAD=escape|noescape (default escape)

N   = Integer(ENV["N"] || "1")
DUR = Float(ENV["DUR"] || "3")
RubyVM::YJIT.enable if ENV["YJIT"] == "1" && defined?(RubyVM::YJIT.enable)
mode = ENV["WORKLOAD"] || "escape"

# The one-line difference. `-> { a }` captures the local `a`, forcing the frame
# environment onto the heap (the EP escape); the arithmetic version does not.
ESCAPE   = Ractor.shareable_proc { a = 1; f = -> { a }; f.object_id & 1 }
NOESCAPE = Ractor.shareable_proc { a = 1; (a + 1) & 1 }
WORK = mode == "noescape" ? NOESCAPE : ESCAPE

warn "[yjit] enabled=#{(RubyVM::YJIT.enabled? rescue :na)}  workload=#{mode}"

done = Ractor::Port.new
N.times do
  Ractor.new(WORK, DUR, done) do |work, dur, done|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + dur
    n = 0
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      work.call
      n += 1
    end
    done << n
  end
end

total = 0
N.times { total += done.receive }
printf("yjit=%s workload=%-8s N=%d  ops/s=%d  per-worker=%d\n",
       ENV["YJIT"] || "0", mode, N, (total / DUR).to_i, (total.to_f / DUR / N).to_i)
