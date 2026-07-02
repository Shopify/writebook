# frozen_string_literal: true

# The `useragent` gem (used by ActionController::AllowBrowser via
# `allow_browser versions: :modern`) keeps mutable lookup tables in constants
# such as UserAgent::Browsers::Chrome::ChromeBrowsers. Parsing a user-agent in a
# non-main Ractor reads those constants, so they must be Ractor-shareable.
require "active_support/ractors"

ActiveSupport::Ractors.on_freeze do
  next unless defined?(UserAgent)

  # Ensure the browser matchers are loaded, then deep-freeze every value
  # constant under the UserAgent namespace.
  require "useragent"

  freeze_constants = lambda do |mod, seen|
    next if seen.include?(mod)
    seen << mod

    mod.constants(false).each do |name|
      value = mod.const_get(name)
      if value.is_a?(Module)
        freeze_constants.call(value, seen)
      else
        Ractor.make_shareable(value) unless Ractor.shareable?(value)
      end
    end
  end

  freeze_constants.call(UserAgent, [])
end
