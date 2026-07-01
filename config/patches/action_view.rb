# frozen_string_literal: true

# actionview — template resolvers & the PathRegistry
#
# The template resolver registry lives in ActionView::PathRegistry module class
# ivars (@view_paths_by_class, @file_system_resolvers). The resolvers hold
# mutable, mutex-guarded template caches (a Concurrent::Map) and a memoized
# Regexp path parser, so they aren't Ractor-shareable as-is.
#
# These caches are only used to look up *file* templates. Rendering inline
# content (e.g. Rails::HealthController's `render html:`) never touches them, so
# for the experiment we shed them on freeze, which lets the whole registry be
# made shareable and read from a non-main Ractor. (A complete solution would use
# Ractor-local template caches, as the upstream ractor-safe work does.)
require "action_view"
require "action_view/path_registry"

module RactorPatches
  module ResolverShareable
    def freeze
      # Replace the mutable Concurrent::Map cache with a frozen empty Hash: it
      # still responds to #values (used by #built_templates) but is shareable.
      # Actual file-template lookup (#compute_if_absent) isn't exercised by an
      # inline `render html:` response.
      @unbound_templates = {}.freeze if instance_variable_defined?(:@unbound_templates)
      @path_parser = nil if instance_variable_defined?(:@path_parser)
      super
    end
  end

  module PathRegistryRactor
    # Read during exception-backtrace building; degrade in a non-main Ractor.
    def all_resolvers
      super
    rescue Ractor::IsolationError
      raise if Ractor.main?
      []
    end

    def all_file_system_resolvers
      super
    rescue Ractor::IsolationError
      raise if Ractor.main?
      []
    end
  end

  # ActionView::LookupContext::DetailsKey.view_context_class memoizes an
  # anonymous ActionView::Base subclass under a Mutex. Once built (we warm it at
  # boot) the memoized class is shareable; skip the Mutex in a non-main Ractor.
  module DetailsKeyRactor
    def view_context_class
      return super if Ractor.main?
      @view_context_class
    end
  end

  # ActionView::Rendering::ClassMethods#view_context_class memoizes a per-
  # controller view context class and rebuilds it when `klass.changed?` is true.
  # `changed?` calls #compiled_method_container, defined with an unshareable Proc
  # (define_singleton_method) that can't be called cross-Ractor. In a frozen app
  # the view context class never changes, so return the (pre-warmed) memoized
  # class in a non-main Ractor.
  module RenderingClassMethodsRactor
    def view_context_class
      return super if Ractor.main?
      @view_context_class
    end
  end
end

ActionView::Resolver.prepend(RactorPatches::ResolverShareable)
ActionView::PathRegistry.singleton_class.prepend(RactorPatches::PathRegistryRactor)
ActionView::LookupContext::DetailsKey.singleton_class.prepend(RactorPatches::DetailsKeyRactor)
ActionView::Rendering::ClassMethods.prepend(RactorPatches::RenderingClassMethodsRactor)

RactorPatches.freeze_runtime_constants << -> do
  ActionView::LookupContext::DetailsKey.view_context_class # warm @view_context_class
end

# ActionView::Base.default_formats is a cattr read by the :formats lookup detail.
RactorPatches.capture_class_reader(ActionView::Base, :default_formats)

# Make the view-path registry shareable so `get_view_paths` works in a Ractor.
RactorPatches.freeze_runtime_constants << -> do
  registry = ActionView::PathRegistry
  %i[@view_paths_by_class @file_system_resolvers].each do |ivar|
    value = registry.instance_variable_get(ivar)
    next if value.nil? || Ractor.shareable?(value)
    registry.instance_variable_set(ivar, Ractor.make_shareable(value))
  end

  # LookupContext.default_procs is a frozen Hash of {detail => default block}.
  # At request time only its keys are read (registered_details); convert the
  # proc values to self-detached shareable procs so the hash is shareable.
  procs = ActionView::LookupContext.default_procs
  shareable = procs.to_h do |key, value|
    [key, Ractor.shareable?(value) ? value : Ractor.shareable_proc(&value)]
  end
  ActionView::LookupContext.default_procs = Ractor.make_shareable(shareable) unless Ractor.shareable?(procs)

  # register_detail also defines `default_<name>` methods on Accessors via
  # define_method(&block) with the original (unshareable) block; those can't be
  # called cross-Ractor. Redefine them with the shareable procs (e.g. formats=
  # calls default_formats when the Accept header contains */*).
  shareable.each do |name, proc|
    ActionView::LookupContext::Accessors.define_method(:"default_#{name}", &proc)
  end
end
