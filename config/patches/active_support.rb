# frozen_string_literal: true

# activesupport — ActiveSupport::Callbacks
#
# A class's callback chains live in the `__callbacks` class_attribute (a class
# ivar). Making the whole chain Ractor-shareable is deep: the compiled callback
# lambdas are bound to unshareable `self`, chains hold a Mutex and memoized
# sequences, and terminators are plain (unshareable) procs.
#
# Following the upstream ractor-safe-rails work, we degrade gracefully instead:
# in a non-main Ractor, if the callback chain can't be read (it isn't
# shareable), run the protected block directly without the surrounding
# callbacks. This lets the controller action (invoked inside
# `run_callbacks(:process_action) { ... }`) still execute.
require "active_support/callbacks"

module RactorPatches
  module CallbacksRunFallback
    def run_callbacks(*args, &block)
      super
    rescue Ractor::IsolationError
      raise if Ractor.main?
      block ? block.call : true
    end
  end
end

ActiveSupport::Callbacks.prepend(RactorPatches::CallbacksRunFallback)

# ActiveSupport::LogSubscriber.logger memoizes @logger (= Rails.logger) onto each
# subscriber class. In a non-main Ractor we can't set a class ivar; return
# Rails.logger (already shareable) directly.
require "active_support/log_subscriber"

module RactorPatches
  module LogSubscriberRactor
    def logger
      return super if Ractor.main?
      (defined?(Rails) && Rails.respond_to?(:logger)) ? Rails.logger : nil
    end

    # flush_all! memoizes @supports_flush on the class; skip that in a Ractor and
    # just flush the (shareable) logger directly.
    def flush_all!
      return super if Ractor.main?
      logger.flush if logger.respond_to?(:flush)
    end
  end
end

ActiveSupport::LogSubscriber.singleton_class.prepend(RactorPatches::LogSubscriberRactor)

# ActiveSupport::Notifications keeps a global @notifier (a Fanout with
# subscribers, mutexes, ...) that is not Ractor-shareable. Making the whole
# instrumentation pipeline shareable is a large subsystem change; instead, in a
# non-main Ractor where the notifier can't be read, run the instrumented block
# directly without publishing events.
require "active_support/notifications"

module RactorPatches
  module NotificationsInstrumentFallback
    def instrument(name, payload = {}, &block)
      super
    rescue Ractor::IsolationError
      raise if Ractor.main?
      block ? yield(payload) : nil
    end

    # Some middleware (e.g. Rails::Rack::Logger) grab the instrumenter directly
    # and call #start/#finish on it. In a non-main Ractor return a stateless
    # no-op instrumenter instead of touching the global @notifier.
    def instrumenter
      super
    rescue Ractor::IsolationError
      raise if Ractor.main?
      ActiveSupport::Notifications::NullInstrumenter.new
    end
  end
end

ActiveSupport::Notifications.singleton_class.prepend(RactorPatches::NotificationsInstrumentFallback)

# ActiveSupport::ErrorReporter dispatches to subscribers and reads per-execution
# state that isn't Ractor-shareable. Error *reporting* is a main-Ractor concern;
# in a non-main Ractor, don't report (the exception still propagates normally).
require "active_support/error_reporter"

module RactorPatches
  module ErrorReporterFallback
    def report(error, **kwargs)
      return nil unless Ractor.main?
      super
    end
  end
end

ActiveSupport::ErrorReporter.prepend(RactorPatches::ErrorReporterFallback)

# ActiveSupport::Cache::Strategy::LocalCache#local_cache_key memoizes a key onto
# the cache store instance. ractorize! freezes the store, so warm the key first
# (before freezing) to avoid a write from a non-main Ractor.
RactorPatches.warmups << -> do
  store = Rails.cache
  store.send(:local_cache_key) if store.respond_to?(:local_cache_key, true)
end

# ActiveSupport::Inflector memoizes the inflections singleton in a class ivar
# (@__en_instance__). String#camelize/underscore read it on the request path
# (e.g. resolving a controller class name). Freeze the stored instance so the
# class ivar holds a shareable value a non-main Ractor can read.
require "active_support/inflector"

RactorPatches.freeze_runtime_constants << -> do
  inflections = ActiveSupport::Inflector::Inflections.instance(:en)
  # Warm the lazily-built uncountables pattern before freezing.
  inflections.uncountables.uncountable?("sheep")
  Ractor.make_shareable(inflections)
end
