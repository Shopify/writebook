# frozen_string_literal: true
#
# Sequential (concurrency 1) latency probe against a running server. Logs in,
# then measures a dispatch gradient of endpoints; prints one CSV line per
# endpoint. Reads x-rz-* headers (present only in Ractor mode w/ RACTOR_METRICS)
# to decompose server time into worker vs main-Ractor and dispatch count.
#
# Env: HOST PORT MODE N WARMUP ADMIN_EMAIL ADMIN_PASSWORD
# Output: LAT,<mode>,<endpoint>,<ok>/<total>,<p50>,<p90>,<p99>,<max>,<wall>,<app>,<main>,<worker>,<disp>
require "net/http"

HOST     = ENV.fetch("HOST", "127.0.0.1")
PORT     = Integer(ENV.fetch("PORT", "3998"))
MODE     = ENV.fetch("MODE", "?")
N        = Integer(ENV.fetch("N", "200"))
WARMUP   = Integer(ENV.fetch("WARMUP", "40"))
EMAIL    = ENV.fetch("ADMIN_EMAIL", "admin@example.com")
PASSWORD = ENV.fetch("ADMIN_PASSWORD", "secret123456")
UA       = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"

# path, needs_auth
ENDPOINTS = [
  ["/up",          false],
  ["/session/new", false],
  ["/",            true],
]

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

$cookies = {}
def cookie_header = $cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
def store_cookies(resp)
  Array(resp.get_fields("set-cookie")).each do |c|
    k, v = c.split(";", 2).first.split("=", 2)
    $cookies[k] = v if k && v
  end
end

def get(http, path)
  req = Net::HTTP::Get.new(path)
  req["User-Agent"] = UA
  req["Cookie"] = cookie_header unless $cookies.empty?
  http.request(req)
end

def pct(sorted, p)
  return 0.0 if sorted.empty?
  sorted[[(p / 100.0 * (sorted.size - 1)).round, sorted.size - 1].min]
end
def avg(a) = a.empty? ? 0.0 : a.sum / a.size

http = Net::HTTP.new(HOST, PORT)
http.open_timeout = 10
http.read_timeout = 60
http.start

# --- log in (session cookie for authenticated endpoints) ---
resp = get(http, "/session/new")
store_cookies(resp)
token = resp.body[/name="authenticity_token"[^>]*value="([^"]*)"/, 1] ||
        resp.body[/value="([^"]*)"[^>]*name="authenticity_token"/, 1]
login_req = Net::HTTP::Post.new("/session")
login_req["User-Agent"] = UA
login_req["Cookie"] = cookie_header
login_req.set_form_data("authenticity_token" => token, "email_address" => EMAIL, "password" => PASSWORD)
login_resp = http.request(login_req)
store_cookies(login_resp)
unless [301, 302, 303].include?(login_resp.code.to_i)
  warn "[#{MODE}] login failed (HTTP #{login_resp.code}); authenticated endpoints will 302"
end

ENDPOINTS.each do |path, _auth|
  WARMUP.times { get(http, path) }

  client_ms = []
  wall = []; app = []; main = []; disp = []
  codes = Hash.new(0)
  N.times do
    t = now
    r = get(http, path)
    client_ms << (now - t) * 1000
    codes[r.code] += 1
    wall << r["x-rz-wall"].to_f if r["x-rz-wall"]
    app  << r["x-rz-app"].to_f  if r["x-rz-app"]
    main << r["x-rz-main"].to_f if r["x-rz-main"]
    disp << r["x-rz-dispatches"].to_f if r["x-rz-dispatches"]
  end

  s = client_ms.sort
  ok = codes.select { |c, _| c.to_i < 400 }.values.sum
  worker = app.empty? ? [] : app.each_with_index.map { |a, i| a - (main[i] || 0) }
  puts [
    "LAT", MODE, path, "#{ok}/#{N}",
    pct(s, 50).round(2), pct(s, 90).round(2), pct(s, 99).round(2), s.last.round(2),
    avg(wall).round(2), avg(app).round(2), avg(main).round(2), avg(worker).round(2),
    avg(disp).round(1)
  ].join(",")
end

http.finish
