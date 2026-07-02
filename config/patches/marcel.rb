# frozen_string_literal: true

# marcel (used by ActiveStorage for MIME-type detection) keeps its lookup
# tables (EXTENSIONS, MAGIC, TYPE_EXTS, TYPE_PARENTS, ...) in mutable module
# constants that are read when detecting a blob's content type. Attaching a
# file in a non-main Ractor reads them, so freeze them to be Ractor-shareable.
require "active_support/ractors"
require "marcel"

ActiveSupport::Ractors.on_freeze do
  next unless defined?(Marcel)

  freeze_constants = lambda do |mod, seen|
    next if seen.include?(mod)
    seen << mod
    mod.constants(false).each do |name|
      value = begin
        mod.const_get(name)
      rescue StandardError
        next
      end
      if value.is_a?(Module)
        freeze_constants.call(value, seen)
      elsif !Ractor.shareable?(value)
        Ractor.make_shareable(value)
      end
    end
  end

  freeze_constants.call(Marcel, [])
end
