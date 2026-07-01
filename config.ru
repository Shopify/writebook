# This file is used by Rack-based servers to start the application.

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
