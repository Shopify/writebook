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

module RactorPatches
  class << self
    attr_accessor :i18n_default_locale, :i18n_available_locales, :i18n_fallbacks
  end

  module I18nConfigRactor
    def default_locale
      return RactorPatches.i18n_default_locale unless Ractor.main?
      super
    end

    def available_locales
      return RactorPatches.i18n_available_locales unless Ractor.main?
      super
    end
  end

  module I18nModuleRactor
    def fallbacks
      return RactorPatches.i18n_fallbacks unless Ractor.main? || RactorPatches.i18n_fallbacks.nil?
      super
    end
  end
end

I18n::Config.prepend(RactorPatches::I18nConfigRactor)
I18n.singleton_class.prepend(RactorPatches::I18nModuleRactor)

RactorPatches.freeze_runtime_constants << -> do
  RactorPatches.i18n_default_locale = I18n.default_locale
  RactorPatches.i18n_available_locales = Ractor.make_shareable(I18n.available_locales.dup)
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
