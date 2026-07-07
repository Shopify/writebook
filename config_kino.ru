# Run the ractorized app under Kino, a Ractor-native web server (Rust front-end
# owns the network; worker Ractors run the Rack app). Unlike config.ru's
# RactorPatches::Bridge, Kino does the Ractor dispatch itself, so here we just
# make the app shareable and hand it to Kino. Used by script/memory_saturation.sh.
#
#   bundle exec kino --check config_kino.ru               # shareability report
#   bundle exec kino -m ractor -w 4 -t 1 -p 3987 config_kino.ru
#
# Needs the kino fork from the Gemfile (pins magnus git for the Ruby 4.1 ABI).
# State: /up works in :ractor mode; authenticated / SEGVs under concurrent load
# (AR associations / SimpleDelegator) -- an open Ractor-concurrency bug.
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"
ENV["DISABLE_SSL"] ||= "1"

require_relative "config/environment"
Rails.application.load_server
Rails.application.ractorize! unless Rails.application.frozen?

# Create the DB dispatch executor on the MAIN Ractor before Kino spawns workers
# (a worker Ractor can't create it).
require "ractor/dispatch"
Ractor::Dispatch.main

app = Rails.application

# Kino runs `app` directly inside each worker Ractor, so replicate what
# RactorPatches::Bridge does per worker: give this Ractor its own empty
# connection handler (real DB work is dispatched to the main Ractor). Done once
# per worker thread; without it, AR's per-request executor hooks read the shared
# connection-handler class-ivar from a non-main Ractor and raise IsolationError.
kino_app = Ractor.shareable_proc do |env|
  unless Thread.current[:kino_conn]
    ActiveRecord::Base.connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
    Thread.current[:kino_conn] = true
  end
  app.call(env)
end

run kino_app
