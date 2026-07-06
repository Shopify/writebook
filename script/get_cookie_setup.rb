# Onboards (GET+POST /first_run) against an empty DB and prints the resulting
# authenticated session cookie header to stdout. Used by memory_saturation.sh.
require "net/http"
HOST = ENV.fetch("HOST", "127.0.0.1")
PORT = Integer(ENV.fetch("PORT", "3996"))
UA   = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"
$c = {}
def ch = $c.map { |k, v| "#{k}=#{v}" }.join("; ")
def store(r) = Array(r.get_fields("set-cookie")).each { |c| k, v = c.split(";").first.split("=", 2); $c[k] = v if k && v }
def csrf(b) = b[/name="authenticity_token"[^>]*value="([^"]*)"/, 1]

h = Net::HTTP.new(HOST, PORT); h.start
g = Net::HTTP::Get.new("/first_run"); g["User-Agent"] = UA; r = h.request(g); store(r); tok = csrf(r.body)
p = Net::HTTP::Post.new("/first_run"); p["User-Agent"] = UA; p["Cookie"] = ch
p.set_form_data("authenticity_token" => tok, "user[name]" => "Admin",
                "user[email_address]" => "a@b.co", "user[password]" => "secret123456")
r = h.request(p); store(r)
warn "onboard -> #{r.code}"
puts ch
