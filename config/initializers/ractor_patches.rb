# frozen_string_literal: true

# Ractor-safety experiment.
#
# The framework (Rails) Ractor patches now live in the Rails fork and are applied
# by `Rails.application.ractorize!` via ActiveSupport::Ractors' before_freeze /
# on_freeze callbacks. This file only carries:
#
#   * patches for non-Rails gems (config/patches/*.rb), which register into the
#     same ActiveSupport::Ractors callbacks, and
#   * the Rack bridge that runs each request inside a non-main Ractor.
require "stringio"

module RactorPatches
  # Storage for values captured on the main Ractor and served to non-main
  # Ractors (used by the i18n gem patch).
  class << self
    attr_accessor :i18n_default_locale, :i18n_available_locales, :i18n_fallbacks, :i18n_enforce_available_locales, :i18n_available_locales_set
  end

  # Opt-in per-request timing (benchmarking only; see script/latency_compare.sh).
  # When RACTOR_METRICS=1, the bridge emits x-rz-* response headers decomposing
  # each request into worker vs main-Ractor time and dispatch count.
  def self.metrics? = ENV["RACTOR_METRICS"] == "1"

  # Wraps Ractor::Dispatch main dispatches to accumulate, per worker Ractor
  # (thread-local), the wall time spent waiting on the main Ractor and the
  # number of dispatches. All DB/render/etc. work funnels through Executor#run.
  module ExecutorMetrics
    # Categorize each main-Ractor dispatch by its caller and accumulate its wall
    # time (thread-local) into DB (connection proxy) vs other (Ractor-unsafe
    # C-extension work on main: Markdown/Redcarpet, HTML sanitize/Loofah,
    # image analysis/vips).
    def run(&block)
      db  = caller_locations(1, 8).any? { |l| l.path.include?("active_record/ractor_patches") }
      key = db ? :rz_db_ns : :rz_oth_ns
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      result = super
      Thread.current[key]            = (Thread.current[key] || 0) + (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t)
      Thread.current[:rz_main_count] = (Thread.current[:rz_main_count] || 0) + 1
      result
    end
  end

  # Rack app that runs each request inside a non-main Ractor.
  #
  # A real Rack env holds non-shareable, non-copyable objects (the socket IO for
  # rack.input, hijack procs, puma.* internals), so we copy the plain CGI-style
  # keys, read the body to a String, and rebuild rack.input/rack.errors inside
  # the Ractor. The Ractor then invokes the frozen, shareable Rails.application
  # through the full middleware stack and returns [status, headers, body].
  class Bridge
    # Pool size: number of persistent worker Ractors. RACTOR_POOL=0 falls back to
    # spawning one ephemeral Ractor per request (the original behavior).
    POOL_SIZE = Integer(ENV.fetch("RACTOR_POOL", "4"))

    @pool_mutex = Mutex.new

    def call(env)
      body = (input = env["rack.input"]) ? input.read : ""

      safe_env = {}
      env.each do |key, value|
        safe_env[key] = value if value.is_a?(String) || value.is_a?(Integer) ||
          value.equal?(true) || value.equal?(false)
      end

      metrics = RactorPatches.metrics?
      wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      st, h, buffer =
        if POOL_SIZE.positive?
          Bridge.pool.call(safe_env, body, metrics)
        else
          Ractor.new(safe_env, body, metrics) do |e, b, m|
            ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
            RactorPatches::Bridge.handle(e, b, m)
          end.value
        end

      h["x-rz-wall"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_start) * 1000).round(3).to_s if metrics
      [st, h, [buffer]]
    end

    # Lazily build the pool on first request (guaranteed after ractorize! froze
    # the application graph).
    def self.pool
      @pool || @pool_mutex.synchronize { @pool ||= WorkerPool.new(POOL_SIZE) }
    end

    # Runs one request. Called inside a worker Ractor. Rebuilds rack.input/errors
    # (the real socket IO can't cross Ractors), invokes the frozen shareable
    # Rails.application, and returns a copyable [status, headers, body].
    #
    # Rescues *everything* so a per-request failure -- notably the cross-Ractor
    # compiled-template Proc race that appears under concurrency -- surfaces as a
    # logged 500 instead of silently killing the worker Ractor, letting us both
    # keep serving and capture the backtrace.
    def self.handle(ractor_env, ractor_body, metrics)
      ractor_env = ractor_env.dup
      ractor_env["rack.input"]  = StringIO.new(ractor_body)
      ractor_env["rack.errors"] = StringIO.new(+"")
      ractor_env["rack.url_scheme"] ||= "http"

      if metrics
        Thread.current[:rz_db_ns] = Thread.current[:rz_oth_ns] = Thread.current[:rz_main_count] = 0
      end

      app_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      st, hdrs, rack_body = Rails.application.call(ractor_env)
      buffer = +""
      rack_body.each { |chunk| buffer << chunk }
      rack_body.close if rack_body.respond_to?(:close)
      h = hdrs.to_h
      if metrics
        app_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - app_start) * 1000
        h["x-rz-app"]        = app_ms.round(3).to_s
        h["x-rz-main-db"]    = ((Thread.current[:rz_db_ns]  || 0) / 1_000_000.0).round(3).to_s
        h["x-rz-main-other"] = ((Thread.current[:rz_oth_ns] || 0) / 1_000_000.0).round(3).to_s
        h["x-rz-dispatches"] = (Thread.current[:rz_main_count] || 0).to_s
      end
      [st, h, buffer]
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn "[ractor-pool] #{e.class}: #{e.message}"
      warn(e.backtrace.first(40).join("\n")) if e.backtrace
      [500, { "content-type" => "text/plain; charset=utf-8" }, +"ractor worker error: #{e.class}: #{e.message}"]
    end
  end

  # A fixed pool of persistent worker Ractors. Each worker owns its own (empty)
  # connection handler and an inbox Port. The pool hands each request to an idle
  # worker and reads the reply from a per-request Port; up to POOL_SIZE requests
  # run in separate Ractors -- and thus on separate cores -- simultaneously.
  class WorkerPool
    def initialize(size)
      @idle = Queue.new
      @workers = Array.new(size) { spawn_worker }
    end

    def size = @workers.size

    def call(safe_env, body, metrics)
      inbox = @idle.pop # blocks until a worker is free (backpressure)
      reply = Ractor::Port.new
      inbox << [safe_env, body, metrics, reply]
      reply.receive
    ensure
      @idle << inbox if inbox
    end

    private

    def spawn_worker
      setup = Ractor::Port.new
      ractor = Ractor.new(setup) do |setup|
        inbox = Ractor::Port.new
        setup << inbox
        # DB access is dispatched to main, so this worker owns no pools; the
        # empty handler lets per-request executor hooks run as no-ops.
        ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
        loop do
          safe_env, body, metrics, reply = inbox.receive
          reply << RactorPatches::Bridge.handle(safe_env, body, metrics)
        end
      end
      @idle << setup.receive # the worker's inbox port
      ractor
    end
  end
end

# Non-Rails gem patches register their before_freeze/on_freeze callbacks here.
Dir[Rails.root.join("config/patches/*.rb")].sort.each { |file| require file }
