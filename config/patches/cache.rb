# frozen_string_literal: true

# The application's cache store (config/environments/production.rb uses
# :null_store) is captured by callbacks such as `rate_limit` and read on the
# request path. To run those callbacks inside a non-main Ractor the store must
# be Ractor-shareable.
#
# The store's @middleware only exists to be inserted into the Rack stack at boot
# (its @app references the whole middleware stack, which is unshareable); it is
# unused for read/write afterwards, so drop it. @options is a plain config hash.
# NullStore's reads/writes are no-ops, so freezing it changes no behavior.
require "active_support/ractors"

ActiveSupport::Ractors.before_freeze do
  store = Rails.cache if defined?(Rails)
  next unless store

  # Warm the per-store local cache key (memoized onto the store) before freezing.
  store.send(:local_cache_key) if store.respond_to?(:local_cache_key, true)

  store.instance_variable_set(:@middleware, nil) if store.instance_variable_defined?(:@middleware)
  if store.instance_variable_defined?(:@options)
    options = store.instance_variable_get(:@options)
    store.instance_variable_set(:@options, Ractor.make_shareable(options.dup)) unless Ractor.shareable?(options)
  end

  Ractor.make_shareable(store)
end
