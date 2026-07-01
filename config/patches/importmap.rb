# frozen_string_literal: true

# importmap-rails (gem) — Importmap::Map is reachable from the application graph
# and frozen by ractorize!. It memoizes the resolved importmap JSON and preload
# paths in @cache (Importmap::Map#cache_as). javascript_importmap_tags reads
# these while rendering the layout. Warm them (with the app's asset resolver)
# before the app is frozen so a non-main Ractor only reads the cache.
require "active_support/ractors"

ActiveSupport::Ractors.before_freeze do
  map = Rails.application.importmap if Rails.application.respond_to?(:importmap)
  if map
    resolver = ApplicationController.helpers
    map.to_json(resolver: resolver) rescue nil
    map.preloaded_module_paths(resolver: resolver) rescue nil
  end
end
