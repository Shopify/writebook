# frozen_string_literal: true
#
# Sequential (concurrency 1) latency probe driving the real onboarding flow.
# Measures, against a running server that starts with an empty DB:
#
#   GET  /up          x N        (no DB)
#   GET  /first_run   x N        (setup form; renders only while there are no users)
#   POST /first_run   x N_POST   (creates account+admin+book+cover+demo, logs in)
#                                 -- the DB is wiped before each one (see reset_db!)
#                                 so it actually runs every time.
#   GET  /            x N        (authenticated library, via the last POST's session)
#
# Reads x-rz-* headers (Ractor mode w/ RACTOR_METRICS) to split server time into
# worker vs main-Ractor and dispatch count.
#
# Env: HOST PORT MODE N WARMUP N_POST POST_WARMUP DB_PATH ADMIN_EMAIL ADMIN_PASSWORD
# Output (ms): LAT,<mode>,<endpoint>,<ok>/<total>,<p50>,<p90>,<p99>,<max>,<wall>,<app>,<main>,<worker>,<disp>
require "net/http"
require "shellwords"

HOST        = ENV.fetch("HOST", "127.0.0.1")
PORT        = Integer(ENV.fetch("PORT", "3998"))
MODE        = ENV.fetch("MODE", "?")
N           = Integer(ENV.fetch("N", "200"))
WARMUP      = Integer(ENV.fetch("WARMUP", "40"))
N_POST      = Integer(ENV.fetch("N_POST", "20"))
POST_WARMUP = Integer(ENV.fetch("POST_WARMUP", "3"))
DB_PATH     = ENV.fetch("DB_PATH", "storage/db/production.sqlite3")
EMAIL       = ENV.fetch("ADMIN_EMAIL", "admin@example.com")
PASSWORD    = ENV.fetch("ADMIN_PASSWORD", "secret123456")
UA          = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"

# App tables to clear between POST /first_run iterations (foreign_keys OFF, so
# order doesn't matter; intersected with the tables that actually exist).
APP_TABLES = %w[
  accesses sessions leaves pages sections pictures books accounts users
  active_storage_attachments active_storage_blobs active_storage_variant_records
  action_text_rich_texts leaf_search_index
].freeze

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Wipe app rows directly via the sqlite3 CLI (fast; server is idle between the
# sequential requests). Makes /first_run available again (User.any? => false).
def reset_db!
  existing = `sqlite3 #{DB_PATH.shellescape} ".tables" 2>/dev/null`.split
  tables = APP_TABLES & existing
  return if tables.empty?
  sql = +"PRAGMA busy_timeout=5000;\nPRAGMA foreign_keys=OFF;\n"
  tables.each { |t| sql << "DELETE FROM #{t};\n" }
  IO.popen(["sqlite3", DB_PATH], "w") { |io| io.write(sql) }
end

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

# One POST /first_run against an empty DB. Returns [resp, client_ms].
def post_first_run(http)
  reset_db!
  form = get(http, "/first_run"); store_cookies(form)
  req = Net::HTTP::Post.new("/first_run")
  req["User-Agent"] = UA
  req["Cookie"] = cookie_header
  req.set_form_data(
    "authenticity_token" => csrf_token(form.body),
    "user[name]" => "Bench Admin",
    "user[email_address]" => EMAIL,
    "user[password]" => PASSWORD,
  )
  t = now
  resp = http.request(req)
  ms = (now - t) * 1000
  store_cookies(resp)
  [resp, ms]
end

def pct(sorted, p)
  return 0.0 if sorted.empty?
  sorted[[(p / 100.0 * (sorted.size - 1)).round, sorted.size - 1].min]
end
def avg(a) = a.empty? ? 0.0 : a.sum / a.size

def emit(endpoint, total, samples, wall, app, main, disp, ok)
  s = samples.sort
  worker = app.each_with_index.map { |a, i| a - (main[i] || 0) }
  puts [
    "LAT", MODE, endpoint, "#{ok}/#{total}",
    pct(s, 50).round(2), pct(s, 90).round(2), pct(s, 99).round(2), s.last.round(2),
    avg(wall).round(2), avg(app).round(2), avg(main).round(2), avg(worker).round(2),
    avg(disp).round(1)
  ].join(",")
end

def measure_get(http, path)
  WARMUP.times { get(http, path) }
  client = []; wall = []; app = []; main = []; disp = []; ok = 0
  N.times do
    t = now
    r = get(http, path)
    client << (now - t) * 1000
    ok += 1 if r.code.to_i < 400
    wall << r["x-rz-wall"].to_f if r["x-rz-wall"]
    app  << r["x-rz-app"].to_f  if r["x-rz-app"]
    main << r["x-rz-main"].to_f if r["x-rz-main"]
    disp << r["x-rz-dispatches"].to_f if r["x-rz-dispatches"]
  end
  emit(path, N, client, wall, app, main, disp, ok)
end

http = Net::HTTP.new(HOST, PORT)
http.open_timeout = 10
http.read_timeout = 180
http.start

reset_db! # start from empty so the /first_run form renders

measure_get(http, "/up")
measure_get(http, "/first_run")

# POST /first_run x N_POST, DB wiped before each so it does real work every time.
POST_WARMUP.times { post_first_run(http) }
client = []; wall = []; app = []; main = []; disp = []; ok = 0
last = nil
N_POST.times do
  resp, ms = post_first_run(http)
  last = resp
  client << ms
  ok += 1 if [301, 302, 303].include?(resp.code.to_i)
  wall << resp["x-rz-wall"].to_f if resp["x-rz-wall"]
  app  << resp["x-rz-app"].to_f  if resp["x-rz-app"]
  main << resp["x-rz-main"].to_f if resp["x-rz-main"]
  disp << resp["x-rz-dispatches"].to_f if resp["x-rz-dispatches"]
end
warn "[#{MODE}] POST /first_run: only #{ok}/#{N_POST} succeeded" unless ok == N_POST
emit("POST /first_run", N_POST, client, wall, app, main, disp, ok)

# Authenticated library, via the session cookie from the last successful POST.
measure_get(http, "/")

http.finish
