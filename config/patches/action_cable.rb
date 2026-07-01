# frozen_string_literal: true

# actioncable — ActionCable auto-mounts its server at /cable, so the route graph
# reaches the live server singleton and its configuration. Two things there are
# not Ractor-shareable:
#
#   1. ActionCable::Configuration stores `connection_class` and
#      `health_check_application` as lambdas whose `self` is the (unshareable)
#      configuration object. Replace them with self-detached shareable procs
#      that resolve lazily.
#
#   2. ActionCable::Server::Base holds a Monitor (`@mutex`) plus several lazily
#      initialized handles (worker pool, event loop, pubsub, ...). None of these
#      can be frozen. Before any client connects they are all nil except the
#      Monitor, so drop them on freeze. A frozen server cannot accept
#      connections — which is fine for serving plain HTTP requests.
require "action_cable"

module RactorPatches
  module ActionCableConfiguration
    def freeze
      if connection_class && !Ractor.shareable?(connection_class)
        self.connection_class =
          Ractor.shareable_proc { "ApplicationCable::Connection".safe_constantize || ActionCable::Connection::Base }
      end

      if health_check_application && !Ractor.shareable?(health_check_application)
        self.health_check_application =
          Ractor.shareable_proc { |env| Rails::HealthController.action(:show).call(env) }
      end

      super
    end
  end

  module ActionCableServerBase
    def freeze
      @mutex = nil
      @remote_connections = @event_loop = @worker_pool = @executor = @pubsub = @heartbeat_timer = nil
      super
    end
  end
end

ActionCable::Configuration.prepend(RactorPatches::ActionCableConfiguration)
ActionCable::Server::Base.prepend(RactorPatches::ActionCableServerBase)
