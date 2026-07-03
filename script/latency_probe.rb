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
# Env: HOST PORT MODE N WARMUP N_POST POST_WARMUP ADMIN_EMAIL ADMIN_PASSWORD
# Output (ms): LAT,<mode>,<endpoint>,<ok>/<total>,<p50>,<p90>,<p99>,<max>,<wall>,<app>,<main>,<worker>,<disp>
require "net/http"
# Boot the app once (in THIS probe process, not the server) so we can wipe
# records between POST /first_run iterations via ActiveRecord -- cheap after the
# one-time boot, and correct at the model layer (vs raw SQL). Never ractorizes
# (that only happens in config.ru), so it's a plain AR connection to the same DB.
require_relative "../config/environment"

HOST        = ENV.fetch("HOST", "127.0.0.1")
PORT        = Integer(ENV.fetch("PORT", "3998"))
MODE        = ENV.fetch("MODE", "?")
N           = Integer(ENV.fetch("N", "200"))
WARMUP      = Integer(ENV.fetch("WARMUP", "40"))
N_POST      = Integer(ENV.fetch("N_POST", "20"))
POST_WARMUP = Integer(ENV.fetch("POST_WARMUP", "3"))
EMAIL       = ENV.fetch("ADMIN_EMAIL", "admin@example.com")
PASSWORD    = ENV.fetch("ADMIN_PASSWORD", "secret123456")
UA          = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"

# Deleted (children-ish first, and with FKs off) to make /first_run available
# again (User.any? => false). delete_all skips callbacks -- fine for a wipe.
RESET_MODELS = %w[
  ActiveStorage::Attachment ActiveStorage::VariantRecord ActiveStorage::Blob
  ActionText::RichText Access Session Leaf Page Section Picture Book Account User
].filter_map { |n| n.safe_constantize }

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def reset_db!
  conn = ActiveRecord::Base.connection
  conn.execute("PRAGMA foreign_keys=OFF")
  RESET_MODELS.each { |m| m.delete_all if m.table_exists? }
  conn.execute("DELETE FROM leaf_search_index") rescue nil
ensure
  conn.execute("PRAGMA foreign_keys=ON") rescue nil
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

# main time is split into 2 buckets: db (connection proxy) and other (Ractor-
# unsafe C-extension work that must run on main: Markdown render/Redcarpet, HTML
# sanitize/Loofah, image analysis/vips). worker = app - all main.
def emit(endpoint, total, samples, wall, app, db, oth, disp, ok)
  s = samples.sort
  worker = app.each_with_index.map { |a, i| a - ((db[i] || 0) + (oth[i] || 0)) }
  puts [
    "LAT", MODE, endpoint, "#{ok}/#{total}",
    pct(s, 50).round(2), pct(s, 90).round(2), pct(s, 99).round(2), s.last.round(2),
    avg(wall).round(2), avg(app).round(2),
    avg(db).round(2), avg(oth).round(2), avg(worker).round(2),
    avg(disp).round(1)
  ].join(",")
end

def collect(r, wall, app, db, oth, disp)
  wall << r["x-rz-wall"].to_f       if r["x-rz-wall"]
  app  << r["x-rz-app"].to_f        if r["x-rz-app"]
  db   << r["x-rz-main-db"].to_f    if r["x-rz-main-db"]
  oth  << r["x-rz-main-other"].to_f if r["x-rz-main-other"]
  disp << r["x-rz-dispatches"].to_f if r["x-rz-dispatches"]
end

def measure_get(http, path)
  WARMUP.times { get(http, path) }
  client = []; wall = []; app = []; db = []; oth = []; disp = []; ok = 0
  N.times do
    t = now
    r = get(http, path)
    client << (now - t) * 1000
    ok += 1 if r.code.to_i < 400
    collect(r, wall, app, db, oth, disp)
  end
  emit(path, N, client, wall, app, db, oth, disp, ok)
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
client = []; wall = []; app = []; db = []; oth = []; disp = []; ok = 0
N_POST.times do
  resp, ms = post_first_run(http)
  client << ms
  ok += 1 if [301, 302, 303].include?(resp.code.to_i)
  collect(resp, wall, app, db, oth, disp)
end
warn "[#{MODE}] POST /first_run: only #{ok}/#{N_POST} succeeded" unless ok == N_POST
emit("POST /first_run", N_POST, client, wall, app, db, oth, disp, ok)

# Authenticated library, via the session cookie from the last successful POST.
measure_get(http, "/")

http.finish
