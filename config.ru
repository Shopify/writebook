# This file is used by Rack-based servers to start the application.

# Ractor-safety experiment runs in production; use an ephemeral secret so the
# server boots without a configured SECRET_KEY_BASE. Must be set before the
# application boots (and reads the secret).
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"

# Disable force_ssl/assume_ssl so the server is reachable over plain http in a
# browser (and so the ActionDispatch::SSL middleware, which isn't Ractor-safe,
# stays out of the stack). See config/environments/production.rb.
ENV["DISABLE_SSL"] ||= "1"

require_relative "config/environment"

Rails.application.load_server

# Ractor-safety experiment: freeze effectively-immutable request-path state and
# make the whole application graph shareable, then serve every request inside a
# non-main Ractor via the bridge. (Only the server boots through config.ru, so
# console/runner/tasks keep a normal, mutable application.)
# ractorize! applies the framework Ractor patches, warms lazily-memoized state,
# deep-freezes the whole application graph, and freezes/shares the remaining
# request-path state (see ActiveSupport::Ractors before_freeze/on_freeze).
if ENV["RACTOR_MODE"] == "0"
  # Benchmark baseline: serve normally, without ractorize! or the Ractor bridge,
  # so the app runs on the main Ractor exactly like an unmodified deploy. Lets
  # script/latency_compare.sh A/B the same build with and without Ractors.
  run Rails.application
else
  # Opt-in per-request timing instrumentation (RACTOR_METRICS=1). Prepend before
  # ractorize! freezes the graph.
  if RactorPatches.metrics?
    require "ractor/dispatch"
    Ractor::Dispatch::Executor.prepend(RactorPatches::ExecutorMetrics)
  end

  Rails.application.ractorize! unless Rails.application.frozen?

  run RactorPatches::Bridge.new
end
