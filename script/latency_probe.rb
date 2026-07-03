# frozen_string_literal: true
#
# Sequential (concurrency 1) latency probe against a running server, driving the
# real onboarding flow -- no manually-seeded user. Assumes the DB starts empty.
#
#   1. GET  /up          x N  (no DB)
#   2. GET  /first_run   x N  (setup form; only renders while there are no users)
#   3. POST /first_run   x 1  (creates account+admin+book+demo, logs in)  [n=1]
#   4. GET  /            x N  (authenticated library, via the session from step 3)
#
# Reads x-rz-* headers (Ractor mode w/ RACTOR_METRICS) to split server time into
# worker vs main-Ractor and dispatch count.
#
# Env: HOST PORT MODE N WARMUP ADMIN_EMAIL ADMIN_PASSWORD
# Output (ms): LAT,<mode>,<endpoint>,<ok>/<total>,<p50>,<p90>,<p99>,<max>,<wall>,<app>,<main>,<worker>,<disp>
#              POST,<mode>,/first_run,<ok>,<ms>,<wall>,<app>,<main>,<disp>
require "net/http"

HOST     = ENV.fetch("HOST", "127.0.0.1")
PORT     = Integer(ENV.fetch("PORT", "3998"))
MODE     = ENV.fetch("MODE", "?")
N        = Integer(ENV.fetch("N", "200"))
WARMUP   = Integer(ENV.fetch("WARMUP", "40"))
EMAIL    = ENV.fetch("ADMIN_EMAIL", "admin@example.com")
PASSWORD = ENV.fetch("ADMIN_PASSWORD", "secret123456")
UA       = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"

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

def csrf_token(body)
  body[/name="authenticity_token"[^>]*value="([^"]*)"/, 1] ||
    body[/value="([^"]*)"[^>]*name="authenticity_token"/, 1]
end

def pct(sorted, p)
  return 0.0 if sorted.empty?
  sorted[[(p / 100.0 * (sorted.size - 1)).round, sorted.size - 1].min]
end
def avg(a) = a.empty? ? 0.0 : a.sum / a.size

# Measure GET path N times (after WARMUP), collecting client latency + x-rz-*.
def measure(http, path)
  WARMUP.times { get(http, path) }
  client = []; wall = []; app = []; main = []; disp = []; codes = Hash.new(0)
  N.times do
    t = now
    r = get(http, path)
    client << (now - t) * 1000
    codes[r.code] += 1
    wall << r["x-rz-wall"].to_f if r["x-rz-wall"]
    app  << r["x-rz-app"].to_f  if r["x-rz-app"]
    main << r["x-rz-main"].to_f if r["x-rz-main"]
    disp << r["x-rz-dispatches"].to_f if r["x-rz-dispatches"]
  end
  s = client.sort
  ok = codes.select { |c, _| c.to_i < 400 }.values.sum
  worker = app.each_with_index.map { |a, i| a - (main[i] || 0) }
  puts [
    "LAT", MODE, path, "#{ok}/#{N}",
    pct(s, 50).round(2), pct(s, 90).round(2), pct(s, 99).round(2), s.last.round(2),
    avg(wall).round(2), avg(app).round(2), avg(main).round(2), avg(worker).round(2),
    avg(disp).round(1)
  ].join(",")
end

http = Net::HTTP.new(HOST, PORT)
http.open_timeout = 10
http.read_timeout = 120
http.start

# 1 + 2: no-user paths (DB must be empty for the /first_run form to render).
measure(http, "/up")
measure(http, "/first_run")

# 3: one real POST /first_run -- creates the account/admin/book/demo and logs in.
form = get(http, "/first_run"); store_cookies(form)
token = csrf_token(form.body)
req = Net::HTTP::Post.new("/first_run")
req["User-Agent"] = UA
req["Cookie"] = cookie_header
req.set_form_data(
  "authenticity_token" => token,
  "user[name]" => "Bench Admin",
  "user[email_address]" => EMAIL,
  "user[password]" => PASSWORD,
)
t = now
resp = http.request(req)
post_ms = (now - t) * 1000
store_cookies(resp)
post_ok = [301, 302, 303].include?(resp.code.to_i)
warn "[#{MODE}] POST /first_run -> HTTP #{resp.code} (expected 3xx)" unless post_ok
puts [
  "POST", MODE, "/first_run", (post_ok ? "ok" : "FAIL(#{resp.code})"),
  post_ms.round(2), resp["x-rz-wall"].to_f.round(2), resp["x-rz-app"].to_f.round(2),
  resp["x-rz-main"].to_f.round(2), resp["x-rz-dispatches"].to_i
].join(",")

# 4: authenticated library.
measure(http, "/")

http.finish
