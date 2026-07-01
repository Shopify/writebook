# Harness: serve a single request from inside a Ractor (in-process demo).
# Run with: bin/rails runner script/ractor_up.rb [PATH]   (PATH defaults to /up)
#
# The Ractor-safety fixes live in config/patches/*.rb (loaded at boot). Here we
# mirror config.ru: warm, ractorize! (rails/rails#57825), harden, then call the
# frozen application from a non-main Ractor.

PATH = (ARGV[0] && !ARGV[0].empty? ? ARGV[0] : "/up")

def build_env(path)
  Rack::MockRequest.env_for(path, "HTTP_HOST" => "localhost", "REMOTE_ADDR" => "127.0.0.1")
end

# Sanity: works on the main ractor.
main_status, _mh, main_body = Rails.application.call(build_env(PATH))
main_out = +""; main_body.each { |b| main_out << b }; main_body.close if main_body.respond_to?(:close)
puts "[main ractor] #{PATH} -> #{main_status}: #{main_out[0, 60]}"

RactorPatches.warm_before_freeze!
Rails.application.ractorize!
puts "[ractorize!] OK: Rails.application shareable? #{Ractor.shareable?(Rails.application)}"
RactorPatches.freeze_runtime_constants!

# Serve the request from inside a Ractor. The env is built inside the Ractor: a
# Rack env holds non-shareable/non-copyable objects (StringIO, etc.). We build a
# plain Hash rather than Rack::MockRequest.env_for, which reads an unshareable
# class-ivar URI parser a non-main Ractor cannot touch.
require "stringio"
r = Ractor.new(PATH) do |path|
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
  puts "[ractor] #{PATH} -> #{ractor_status}: #{ractor_out[0, 80]}"
rescue Ractor::RemoteError => e
  cause = e.cause || e
  puts "[ractor] FAILED: #{cause.class}: #{cause.message}"
  puts cause.backtrace.first(12).map { |l| "    #{l}" }
end
