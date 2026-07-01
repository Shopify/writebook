# This file is used by Rack-based servers to start the application.

# Ractor-safety experiment runs in production; use an ephemeral secret so the
# server boots without a configured SECRET_KEY_BASE. Must be set before the
# application boots (and reads the secret).
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"

# Disable force_ssl/assume_ssl so the server is reachable over plain http in a
# browser (and so the ActionDispatch::SSL middleware, which isn't Ractor-safe,
# stays out of the stack). See config/environments/production.rb.
ENV["DISABLE_SSL"] ||= "1"

require_relative "config/environment"

Rails.application.load_server

# Ractor-safety experiment: freeze effectively-immutable request-path state and
# make the whole application graph shareable, then serve every request inside a
# non-main Ractor via the bridge. (Only the server boots through config.ru, so
# console/runner/tasks keep a normal, mutable application.)
unless Rails.application.frozen?
  RactorPatches.warm_before_freeze!
  Rails.application.ractorize!
  RactorPatches.freeze_runtime_constants!
end

run RactorPatches::Bridge.new
