# frozen_string_literal: true

# i18n — I18n::Config stores its state in class variables (@@default_locale,
# @@available_locales, @@backend, ...). Class variables cannot be read from a
# non-main Ractor at all. A fresh Config is created per thread/Ractor and reads
# these on the request path (e.g. LookupContext computes the :locale detail via
# I18n.locale).
#
# Making all of I18n Ractor-safe is a subsystem change (the upstream ractor-safe
# work has several I18n commits). For the experiment we capture the locale
# configuration at boot and serve it to non-main Ractors, which is all the
# inline `/up` response needs (it performs no translation lookups).
require "i18n"
require "active_support/ractors"

module RactorPatches
  module I18nConfigRactor
    def default_locale
      return RactorPatches.i18n_default_locale unless Ractor.main?
      super
    end

    def available_locales
      return RactorPatches.i18n_available_locales unless Ractor.main?
      super
    end

    def enforce_available_locales
      return RactorPatches.i18n_enforce_available_locales unless Ractor.main?
      super
    end

    def available_locales_set
      return RactorPatches.i18n_available_locales_set unless Ractor.main?
      super
    end
  end

  module I18nModuleRactor
    def fallbacks
      return RactorPatches.i18n_fallbacks unless Ractor.main? || RactorPatches.i18n_fallbacks.nil?
      super
    end

    # Transliteration (used e.g. to build the ASCII Content-Disposition filename
    # for ActiveStorage blob downloads) goes through the I18n backend, which
    # holds Procs and can't be shared with a Ractor. It's a leaf string->string
    # op, so run it on the main Ractor.
    def transliterate(key, throw: false, replacement: nil, locale: nil, **options)
      return super if Ractor.main? || !options.empty?

      transliterate_key = -key.to_s
      transliterate_replacement = replacement ? -replacement.to_s : nil
      transliterate_locale = locale
      Ractor::Dispatch.main.run do
        result = I18n.transliterate(transliterate_key, replacement: transliterate_replacement, locale: transliterate_locale)
        -result.to_s
      end
    end
  end
end

I18n::Config.prepend(RactorPatches::I18nConfigRactor)
I18n.singleton_class.prepend(RactorPatches::I18nModuleRactor)

ActiveSupport::Ractors.on_freeze do
  RactorPatches.i18n_default_locale = I18n.default_locale
  RactorPatches.i18n_available_locales = Ractor.make_shareable(I18n.available_locales.dup)
  RactorPatches.i18n_enforce_available_locales = I18n.config.enforce_available_locales
  RactorPatches.i18n_available_locales_set = Ractor.make_shareable(I18n.config.available_locales_set.dup)
  if I18n.respond_to?(:fallbacks)
    fallbacks = I18n.fallbacks
    fallbacks[I18n.default_locale] # warm the default locale entry
    begin
      RactorPatches.i18n_fallbacks = Ractor.make_shareable(fallbacks)
    rescue Ractor::Error, Ractor::IsolationError
      # Leave nil; the override falls through to super on the main Ractor.
    end
  end
end
