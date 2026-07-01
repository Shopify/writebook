# frozen_string_literal: true

# propshaft (gem) — Propshaft::Assembly is reachable from the application graph
# and is frozen by ractorize!. It lazily memoizes @compilers/@load_path/
# @resolver/@server and the load-path asset caches, which the asset URL helpers
# (image_tag, stylesheet_link_tag, ...) read while rendering. Warm all of that
# before the app is frozen so a non-main Ractor only reads it.
require "active_support/ractors"

ActiveSupport::Ractors.before_freeze do
  assets = Rails.application.assets if Rails.application.respond_to?(:assets)
  if assets
    assets.compilers
    load_path = assets.load_path
    resolver = assets.resolver
    assets.server
    # Warm the load-path asset scan/caches (assets_by_path, etc.).
    load_path.assets rescue nil
    # Warm the Static resolver's parsed manifest (memoized on the resolver).
    resolver.send(:parsed_manifest) if resolver.respond_to?(:parsed_manifest, true)
  end
end
