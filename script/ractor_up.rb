# Harness: serve a single `/up` request from inside a Ractor.
# Run with: bin/rails runner script/ractor_up.rb
#
# The Ractor-safety fixes live in config/patches/*.rb (loaded at boot). Here we
# just freeze the application graph via `ractorize!` and then call it from a
# non-main Ractor.

def build_env
  Rack::MockRequest.env_for("/up", "HTTP_HOST" => "localhost", "REMOTE_ADDR" => "127.0.0.1")
end

# Sanity: works on the main ractor.
main_status, _main_headers, main_body = Rails.application.call(build_env)
main_out = +""; main_body.each { |b| main_out << b }; main_body.close if main_body.respond_to?(:close)
puts "[main ractor] /up -> #{main_status}: #{main_out[0, 60]}"

# Make the whole application graph shareable (rails/rails#57825).
begin
  Rails.application.ractorize!
  puts "[ractorize!] OK: Rails.application shareable? #{Ractor.shareable?(Rails.application)}"
rescue => e
  puts "[ractorize!] FAILED: #{e.class}: #{e.message}"
  raise
end

# After the app graph is frozen, harden the remaining request-path state that
# lives outside it: effectively-immutable constants and controller class-level
# state (registered by config/patches/*.rb). Done post-ractorize so references
# into the (now frozen, shareable) app graph are already shareable.
RactorPatches.freeze_runtime_constants!

# Serve the request from inside a Ractor. `Rails.application` is referenced as a
# constant from the non-main Ractor, which is only allowed because it is now
# shareable.
# Build the env *inside* the Ractor: a Rack env holds non-shareable, non-
# copyable objects (a StringIO for rack.input), so it can't be passed in. We
# build a plain Hash rather than Rack::MockRequest.env_for, which reads an
# unshareable class-ivar URI parser that a non-main Ractor cannot touch.
require "stringio"
r = Ractor.new("/up") do |path|
  ractor_env = {
    "REQUEST_METHOD"  => "GET",
    "SCRIPT_NAME"     => "",
    "PATH_INFO"       => path,
    "QUERY_STRING"    => "",
    "SERVER_NAME"     => "localhost",
    "SERVER_PORT"     => "80",
    "SERVER_PROTOCOL" => "HTTP/1.1",
    "HTTP_HOST"       => "localhost",
    "REMOTE_ADDR"     => "127.0.0.1",
    "rack.url_scheme" => "http",
    "rack.input"      => StringIO.new(""),
    "rack.errors"     => StringIO.new(+""),
  }
  st, _h, bd = Rails.application.call(ractor_env)
  o = +""; bd.each { |b| o << b }; bd.close if bd.respond_to?(:close)
  [st, o]
end
begin
  ractor_status, ractor_out = r.value
  puts "[ractor] /up -> #{ractor_status}: #{ractor_out[0, 60]}"
rescue Ractor::RemoteError => e
  cause = e.cause || e
  puts "[ractor] FAILED: #{cause.class}: #{cause.message}"
  puts cause.backtrace.first(8).map { |l| "    #{l}" }
end
