# frozen_string_literal: true

# JSON keeps its default dump/parse options in mutable module-level Hashes that
# are read on every JSON.dump / JSON.parse. Encrypted session cookies are
# JSON-serialized, so serializing/deserializing them in a non-main Ractor reads
# these options and raises Ractor::IsolationError (breaking session and CSRF).
# They're effectively static config, so freeze them to be Ractor-shareable.
require "active_support/ractors"
require "json"

ActiveSupport::Ractors.on_freeze do
  %i[@dump_default_options @load_default_options @unsafe_load_default_options].each do |ivar|
    next unless JSON.instance_variable_defined?(ivar)
    value = JSON.instance_variable_get(ivar)
    JSON.instance_variable_set(ivar, Ractor.make_shareable(value)) unless Ractor.shareable?(value)
  end
end
