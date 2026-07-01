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
    attr_accessor :i18n_default_locale, :i18n_available_locales, :i18n_fallbacks
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

      result = Ractor.new(safe_env, body) do |ractor_env, ractor_body|
        ractor_env = ractor_env.dup
        ractor_env["rack.input"]  = StringIO.new(ractor_body)
        ractor_env["rack.errors"] = StringIO.new(+"")
        ractor_env["rack.url_scheme"] ||= "http"

        st, hdrs, rack_body = Rails.application.call(ractor_env)
        buffer = +""
        rack_body.each { |chunk| buffer << chunk }
        rack_body.close if rack_body.respond_to?(:close)
        [st, hdrs.to_h, buffer]
      end.value

      [result[0], result[1], [result[2]]]
    end
  end
end

# Non-Rails gem patches register their before_freeze/on_freeze callbacks here.
Dir[Rails.root.join("config/patches/*.rb")].sort.each { |file| require file }
