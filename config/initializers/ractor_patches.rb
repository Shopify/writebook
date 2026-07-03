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
    def run(&block)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      result = super
      Thread.current[:rz_main_ns]    = (Thread.current[:rz_main_ns] || 0) + (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t)
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
    def call(env)
      body = (input = env["rack.input"]) ? input.read : ""

      safe_env = {}
      env.each do |key, value|
        safe_env[key] = value if value.is_a?(String) || value.is_a?(Integer) ||
          value.equal?(true) || value.equal?(false)
      end

      metrics = RactorPatches.metrics?
      wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = Ractor.new(safe_env, body, metrics) do |ractor_env, ractor_body, metrics|
        ractor_env = ractor_env.dup
        ractor_env["rack.input"]  = StringIO.new(ractor_body)
        ractor_env["rack.errors"] = StringIO.new(+"")
        ractor_env["rack.url_scheme"] ||= "http"

        # Give this Ractor its own (empty) connection handler. DB access is
        # dispatched to the main Ractor, so this Ractor owns no pools; the empty
        # handler lets per-request executor hooks (query cache, etc.) run as
        # no-ops instead of reaching the main Ractor's unshareable handler.
        ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new

        app_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        st, hdrs, rack_body = Rails.application.call(ractor_env)
        buffer = +""
        rack_body.each { |chunk| buffer << chunk }
        rack_body.close if rack_body.respond_to?(:close)
        h = hdrs.to_h
        if metrics
          app_ms  = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - app_start) * 1000
          main_ms = (Thread.current[:rz_main_ns] || 0) / 1_000_000.0
          h["x-rz-app"]        = app_ms.round(3).to_s
          h["x-rz-main"]       = main_ms.round(3).to_s
          h["x-rz-dispatches"] = (Thread.current[:rz_main_count] || 0).to_s
        end
        [st, h, buffer]
      end.value

      headers = result[1]
      if metrics
        headers["x-rz-wall"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_start) * 1000).round(3).to_s
      end
      [result[0], headers, [result[2]]]
    end
  end
end

# Non-Rails gem patches register their before_freeze/on_freeze callbacks here.
Dir[Rails.root.join("config/patches/*.rb")].sort.each { |file| require file }
