# frozen_string_literal: true

# rack — Rack::Files (used by ActionDispatch::Static to serve public/ files)
#
# Rack::Files#initialize memoizes `@head = Rack::Head.new(lambda { |env| get env })`.
# That lambda closes over the Files instance (`self`), so it is not
# Ractor-shareable. Rack::Head only strips the body for HEAD requests, so we can
# drop the lambda and inline that behavior in #call instead.
require "rack/files"
require "rack/head"
require "active_support/ractors"

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

ActiveSupport::Ractors.before_freeze do
  Rack::Files.prepend(RactorPatches::RackFiles)
end

# Non-main Ractors cannot read constants whose values are not shareable. Several
# Rack constants hold effectively-immutable objects (e.g. a Regexp built with
# Regexp.union, the MIME type table) that just happen not to be frozen. Freeze
# them so the request path can read them from inside a Ractor.
ActiveSupport::Ractors.on_freeze do
  # Many Rack modules keep effectively-immutable lookup tables / limits /
  # self-contained lambdas in constants that simply aren't frozen (regexps,
  # hashes, arrays, the multipart TEMPFILE_FACTORY, query-parser separators,
  # HTTP method sets, etc.). Recursively make every non-shareable value
  # constant under the Rack namespace shareable so the request path can read
  # them from a non-main Ractor. Constants that can't be frozen (e.g. a lambda
  # closing over an unshareable local) are left as-is.
  freeze_rack_constants = lambda do |mod, seen|
    return if seen.include?(mod)
    seen << mod
    mod.constants(false).each do |name|
      value = begin
        mod.const_get(name)
      rescue StandardError, LoadError
        next
      end
      if value.is_a?(Module)
        freeze_rack_constants.call(value, seen) if value.name&.start_with?("Rack")
      elsif !Ractor.shareable?(value)
        begin
          Ractor.make_shareable(value)
        rescue Ractor::Error, Ractor::IsolationError
          # e.g. a constant lambda closing over an unshareable local.
        end
      end
    end
  end
  freeze_rack_constants.call(Rack, [])

  # Rack::Utils.default_query_parser is a class-ivar QueryParser used to parse
  # query/body params on the request path.
  if Rack::Utils.instance_variable_defined?(:@default_query_parser)
    qp = Rack::Utils.instance_variable_get(:@default_query_parser)
    Rack::Utils.instance_variable_set(:@default_query_parser, Ractor.make_shareable(qp)) unless Ractor.shareable?(qp)
  end

  # Rack::Request keeps class-level configuration in class ivars (the forwarded-
  # header priority and the trusted-proxy ip_filter lambda) that the request
  # path reads. Freeze them so a non-main Ractor can read them.
  %i[@forwarded_priority @forwarded_authority @ip_filter
     @x_forwarded_proto_priority @x_forwarded_host_priority].each do |ivar|
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
