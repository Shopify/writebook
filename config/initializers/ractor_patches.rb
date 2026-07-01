# frozen_string_literal: true

# Ractor-safety experiment (see script/ractor_up.rb).
#
# These patches teach gem/framework objects to shed their unshareable state
# (mutexes, file watchers, self-bound procs, ...) when frozen, so that
# `Rails.application.ractorize!` (rails/rails#57825) can deep-freeze the whole
# application graph and share it with a non-main Ractor.
#
# `Ractor.make_shareable` invokes `#freeze`, so each patch overrides `freeze`
# to remove/replace the offending state before calling `super`.
#
# Some request-path state lives in module *constants* that are not reachable from
# the application object graph (so `ractorize!` won't freeze them) but which a
# non-main Ractor must still be able to read. Patches register a callable in
# `RactorPatches.freeze_runtime_constants`; the harness runs them after boot,
# right before `ractorize!`.
module RactorPatches
  def self.freeze_runtime_constants
    @freeze_runtime_constants ||= []
  end

  def self.freeze_runtime_constants!
    freeze_runtime_constants.each(&:call)
  end

  # Warmups that must run BEFORE ractorize! freezes the app: they force lazy
  # memoization onto objects that will be frozen, so a non-main Ractor later
  # reads the memoized value instead of trying to write it.
  def self.warmups
    @warmups ||= []
  end

  def self.warm_before_freeze!
    warmups.each(&:call)
  end

  # Helper for the recurring case of a class-level reader backed by a class
  # variable (cattr) or class ivar holding an effectively-immutable value.
  # Class variables can't be read from a non-main Ractor at all, so capture the
  # value at boot and serve a shareable copy to non-main Ractors.
  def self.capture_class_reader(mod, name)
    ivar = :"@_ractor_captured_#{name}"
    reader = Module.new
    # Define with a string (not define_method): a method backed by an
    # unshareable Proc can't be called from a non-main Ractor in Ruby 4.0.
    reader.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      def #{name}
        return super if Ractor.main?
        #{mod.name}.instance_variable_get(:#{ivar})
      end
    RUBY
    mod.singleton_class.prepend(reader)
    freeze_runtime_constants << -> do
      value = mod.send(name)
      shareable = begin
        Ractor.make_shareable(value.dup)
      rescue StandardError, TypeError
        Ractor.make_shareable(value)
      end
      mod.instance_variable_set(ivar, shareable)
    end
  end
end

Dir[Rails.root.join("config/patches/*.rb")].sort.each { |file| require file }

require "stringio"

module RactorPatches
  # Rack app that runs each request inside a non-main Ractor.
  #
  # The webserver (Puma) calls #call in the main Ractor. A real Rack env holds
  # non-shareable, non-copyable objects (the socket IO for rack.input, hijack
  # procs, puma.* internals), so we can't hand it to a Ractor directly. Instead
  # we copy the plain (String/Integer/boolean) CGI-style keys, read the body to
  # a String, and rebuild rack.input/rack.errors inside the Ractor. The Ractor
  # then invokes the frozen, shareable Rails.application through the full
  # middleware stack and returns [status, headers, body_string] back across the
  # boundary.
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
