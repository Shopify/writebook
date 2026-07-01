# frozen_string_literal: true

# Application-level constants that the request path reads and that must be
# Ractor-shareable (frozen) to be read from a non-main Ractor.
require "active_support/ractors"

ActiveSupport::Ractors.on_freeze do
  if defined?(TranslationsHelper::TRANSLATIONS)
    Ractor.make_shareable(TranslationsHelper::TRANSLATIONS)
  end
end
