# frozen_string_literal: true

# actionpack — ActionDispatch::Routing::RouteSet
#
# 1. A RouteSet keeps the blocks passed to `routes.prepend` / `routes.append` so
#    it can replay them on a route reload. Railties, engines and several gems
#    register blocks this way (internal `/rails/info` routes in development, the
#    ActionCable mount, ...), and those blocks close over the (unshareable)
#    application. A frozen application never reloads its routes, so drop them.
#
# 2. `direct` / `resolve` route helpers store their block in a CustomUrlHelper.
#    ActiveStorage (and apps) register several of these, and the blocks are not
#    Ractor-shareable by default. They are always invoked via `instance_exec`,
#    which rebinds `self` at call time, so detaching the block's `self` with a
#    shareable proc is safe.
require "action_dispatch/routing/route_set"

module RactorPatches
  module RouteSet
    def freeze
      @prepend&.clear
      @append&.clear
      super
    end
  end

  module CustomUrlHelper
    def freeze
      if block && !Ractor.shareable?(block)
        @block = Ractor.shareable_proc(&block)
      end
      super
    end
  end

  # ActionDispatch::ServerTiming::Subscriber (enabled by config.server_timing)
  # keeps a Mutex that only guards a one-time Notifications subscription. Make
  # sure it is subscribed, then drop the Mutex so it can be frozen.
  module ServerTimingSubscriber
    def freeze
      ensure_subscribed
      @mutex = nil
      super
    end
  end

  # ActionDispatch::ExceptionWrapper reads class variables (@@wrapper_exceptions)
  # and other main-Ractor-only state while classifying an exception. In a non-
  # main Ractor, fall back to the raw exception so the *primary* error still
  # propagates instead of being masked by an IsolationError from the error path.
  module ExceptionWrapperRactor
    def unwrapped_exception
      super
    rescue Ractor::IsolationError
      raise if Ractor.main?
      exception
    end
  end

  # The exception-rendering middleware (ShowExceptions/DebugExceptions) reads
  # class variables (@@rescue_responses, ...) and other main-Ractor-only state
  # while classifying/rendering an error. In a non-main Ractor, bypass the
  # rescue so the original exception propagates (error pages are a main-Ractor
  # concern).
  # status_code_for_exception reads @@rescue_responses directly (bypassing the
  # cattr reader), so route it through the captured value in a non-main Ractor.
  module ExceptionWrapperClassRactor
    def status_code_for_exception(class_name)
      return super if Ractor.main?
      ActionDispatch::Response.rack_status_code(rescue_responses[class_name])
    end
  end

  module ExceptionMiddlewarePassthrough
    def call(env)
      return @app.call(env) unless Ractor.main?
      super
    end
  end
end

ActionDispatch::ShowExceptions.prepend(RactorPatches::ExceptionMiddlewarePassthrough)
ActionDispatch::DebugExceptions.prepend(RactorPatches::ExceptionMiddlewarePassthrough)
ActionDispatch::ExceptionWrapper.prepend(RactorPatches::ExceptionWrapperRactor)
ActionDispatch::ExceptionWrapper.singleton_class.prepend(RactorPatches::ExceptionWrapperClassRactor)
# Class-level readers backed by class variables (cattr) that the request path
# reads: capture their (effectively-immutable) values for non-main Ractors.
RactorPatches.capture_class_reader(ActionDispatch::Response, :default_headers)
RactorPatches.capture_class_reader(ActionDispatch::Response, :default_charset)
RactorPatches.capture_class_reader(ActionDispatch::ParamBuilder, :default)
RactorPatches.capture_class_reader(ActionDispatch::Request, :ignore_accept_header)
RactorPatches.capture_class_reader(ActionDispatch::Request, :strict_accept_header)
RactorPatches.capture_class_reader(ActionDispatch::ExceptionWrapper, :rescue_responses)

RactorPatches.freeze_runtime_constants << -> do
  # ActionDispatch::Request keeps the body parameter parsers in a class ivar
  # (@parameter_parsers), a Hash of {mime => parser proc}, read on the request
  # path. Convert the parser procs to self-detached shareable procs so the hash
  # is shareable.
  parsers = ActionDispatch::Request.parameter_parsers
  unless Ractor.shareable?(parsers)
    shareable = parsers.to_h do |mime, parser|
      [mime, Ractor.shareable?(parser) ? parser : Ractor.shareable_proc(&parser)]
    end
    # Set the ivar directly: the parameter_parsers= writer rebuilds (and thus
    # unfreezes) the hash via transform_keys. Keys are already symbols here.
    ActionDispatch::Request.instance_variable_set(:@parameter_parsers, Ractor.make_shareable(shareable))
  end
end
ActionDispatch::Routing::RouteSet.prepend(RactorPatches::RouteSet)
ActionDispatch::Routing::RouteSet::CustomUrlHelper.prepend(RactorPatches::CustomUrlHelper)
ActionDispatch::ServerTiming::Subscriber.prepend(RactorPatches::ServerTimingSubscriber)

# Non-main Ractors cannot read constants whose values are not shareable. The
# request path reads the Mime registry and the static file handler's
# content-type tables; these are effectively immutable once the app has booted,
# so freeze them. (A read-only shared app never registers new Mime types.)
# Executing a controller action from a non-main Ractor requires the controller
# *class-level* state it reads at request time to be shareable (class_attribute
# values live in class ivars like @__class_attr_config, which a non-main Ractor
# cannot read unless the value is shareable). We only need the attributes that
# are actually read while handling a request, not every class ivar.
module RactorPatches
  CONTROLLER_SHAREABLE_ATTRS = %i[
    @__class_attr_config
    @__class_attr_middleware_stack
    @controller_path
    @action_methods
    @renderer
    @__class_attr__renderers
    @__class_attr_helpers_path
    @__class_attr__wrapper_options
    @__class_attr_rescue_handlers
    @__class_attr_etaggers
    @__class_attr_fragment_cache_keys
    @__class_attr__layout
    @__class_attr__layout_conditions
    @__class_attr_default_url_options
  ].freeze

  def self.share_class_ivars!(klass, ivars)
    ivars.each do |ivar|
      next unless klass.instance_variable_defined?(ivar)
      val = klass.instance_variable_get(ivar)
      next if Ractor.shareable?(val)
      begin
        klass.instance_variable_set(ivar, Ractor.make_shareable(val))
      rescue Ractor::Error, Ractor::IsolationError
        # e.g. a proc-valued class_attribute bound to unshareable state; skip.
      end
    end
  end

  def self.make_controllers_shareable!
    klasses = ActionController::Base.descendants + [ActionController::Metal, ActionController::Base, AbstractController::Base]
    klasses.uniq.each do |klass|
      # Warm the per-controller view context class so a non-main Ractor reads the
      # memoized value instead of building it (which mutates class state).
      klass.view_context_class if klass.respond_to?(:view_context_class) && klass.respond_to?(:_routes)
      share_class_ivars!(klass, CONTROLLER_SHAREABLE_ATTRS)
    end
  end
end

RactorPatches.freeze_runtime_constants << -> { RactorPatches.make_controllers_shareable! }

RactorPatches.freeze_runtime_constants << -> do
  Ractor.make_shareable(Mime::SET)
  Ractor.make_shareable(Mime::LOOKUP)
  Ractor.make_shareable(Mime::EXTENSION_LOOKUP)
  Ractor.make_shareable(Mime::ALL)
  Ractor.make_shareable(ActionDispatch::FileHandler.const_get(:DEFAULT_UTF8_CONTENT_TYPES))
  Ractor.make_shareable(ActionDispatch::FileHandler.const_get(:PRECOMPRESSED))
end
