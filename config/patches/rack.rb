# frozen_string_literal: true

# rack — Rack::Files (used by ActionDispatch::Static to serve public/ files)
#
# Rack::Files#initialize memoizes `@head = Rack::Head.new(lambda { |env| get env })`.
# That lambda closes over the Files instance (`self`), so it is not
# Ractor-shareable. Rack::Head only strips the body for HEAD requests, so we can
# drop the lambda and inline that behavior in #call instead.
require "rack/files"
require "rack/head"

module RactorPatches
  module RackFiles
    def freeze
      @head = nil
      super
    end

    def call(env)
      return super unless frozen?

      status, headers, body = response = get(env)
      if env["REQUEST_METHOD"] == "HEAD"
        body.close if body.respond_to?(:close)
        response[2] = []
      end
      response
    end
  end
end

Rack::Files.prepend(RactorPatches::RackFiles)

# Non-main Ractors cannot read constants whose values are not shareable. Several
# Rack constants hold effectively-immutable objects (e.g. a Regexp built with
# Regexp.union, the MIME type table) that just happen not to be frozen. Freeze
# them so the request path can read them from inside a Ractor.
RactorPatches.freeze_runtime_constants << -> do
  Ractor.make_shareable(Rack::Utils::PATH_SEPS)
  Ractor.make_shareable(Rack::Mime::MIME_TYPES)
  Ractor.make_shareable(Rack::MethodOverride::ALLOWED_METHODS)
  Ractor.make_shareable(Rack::Headers::KNOWN_HEADERS) if defined?(Rack::Headers::KNOWN_HEADERS)
  Ractor.make_shareable(Rack::Utils::SYMBOL_TO_STATUS_CODE) if defined?(Rack::Utils::SYMBOL_TO_STATUS_CODE)
  Ractor.make_shareable(Rack::Utils::HTTP_STATUS_CODES) if defined?(Rack::Utils::HTTP_STATUS_CODES)
  Ractor.make_shareable(Rack::Request::Helpers::FORM_DATA_MEDIA_TYPES)
  Ractor.make_shareable(Rack::Request::Helpers::PARSEABLE_DATA_MEDIA_TYPES)

  # Rack::Utils.default_query_parser is a class-ivar QueryParser used to parse
  # query/body params on the request path.
  if Rack::Utils.instance_variable_defined?(:@default_query_parser)
    qp = Rack::Utils.instance_variable_get(:@default_query_parser)
    Rack::Utils.instance_variable_set(:@default_query_parser, Ractor.make_shareable(qp)) unless Ractor.shareable?(qp)
  end

  # Rack::Request keeps class-level configuration in class ivars (the forwarded-
  # header priority and the trusted-proxy ip_filter lambda) that the request
  # path reads. Freeze them so a non-main Ractor can read them.
  %i[@forwarded_priority @forwarded_authority @ip_filter].each do |ivar|
    next unless Rack::Request.instance_variable_defined?(ivar)
    value = Rack::Request.instance_variable_get(ivar)
    next if Ractor.shareable?(value)
    begin
      Rack::Request.instance_variable_set(ivar, Ractor.make_shareable(value))
    rescue Ractor::Error, Ractor::IsolationError
      # e.g. @ip_filter is a lambda closing over an unshareable Regexp local.
      # Leave it; the /up path doesn't consult it.
    end
  end
end
