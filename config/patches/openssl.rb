# frozen_string_literal: true

# openssl (stdlib) — OpenSSL::Digest defines its concrete subclasses (SHA256,
# MD5, ...) with define_method (initialize/digest/hexdigest), which produces
# methods backed by unshareable procs that can't be called from a non-main
# Ractor. ActiveSupport::Digest (used for template digests) calls
# OpenSSL::Digest::SHA256.hexdigest on the request path. Redefine those methods
# from strings so they're Ractor-callable.
require "openssl"
require "active_support/ractors"

ActiveSupport::Ractors.before_freeze do
  %w[MD4 MD5 RIPEMD160 SHA1 SHA224 SHA256 SHA384 SHA512].each do |name|
    const = name.tr("-", "_")
    next unless OpenSSL::Digest.const_defined?(const)
    klass = OpenSSL::Digest.const_get(const)

    klass.class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      def initialize(data = nil)
        super(#{name.inspect}, data)
      end
    RUBY

    klass.singleton_class.class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      def digest(data)
        new.digest(data)
      end

      def hexdigest(data)
        new.hexdigest(data)
      end
    RUBY
  end
end
