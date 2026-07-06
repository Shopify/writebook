# Sustained authenticated GET / load for a fixed duration. Prints throughput.
#   PORT= COOKIE= DURATION= CONC= ruby script/mem_load.rb
require "net/http"
require "thread"

HOST     = ENV.fetch("HOST", "127.0.0.1")
PORT     = Integer(ENV.fetch("PORT", "3996"))
COOKIE   = ENV.fetch("COOKIE", "")
ENDPOINT = ENV.fetch("ENDPOINT", "/") # NB: not PATH (that's the shell's PATH)
DURATION = Float(ENV.fetch("DURATION", "8"))
CONC     = Integer(ENV.fetch("CONC", "8"))
UA       = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149 Safari/537.36"

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
deadline = now + DURATION
ok = Array.new(CONC, 0)
bad = Array.new(CONC, 0)
lat = Array.new(CONC) { [] } # per-thread client latencies (ms) for successful requests

threads = CONC.times.map do |i|
  Thread.new do
    conn = Net::HTTP.new(HOST, PORT); conn.read_timeout = 60
    conn.start
    req = Net::HTTP::Get.new(ENDPOINT); req["User-Agent"] = UA; req["Cookie"] = COOKIE
    while now < deadline
      begin
        t0 = now
        r = conn.request(req)
        if r.code.to_i == 200 then ok[i] += 1; lat[i] << (now - t0) * 1000 else bad[i] += 1 end
      rescue
        bad[i] += 1
        conn.finish rescue nil; conn.start rescue nil
      end
    end
    conn.finish rescue nil
  end
end
threads.each(&:join)

total_ok = ok.sum
lats = lat.flatten.sort
pct = ->(p) { lats.empty? ? 0.0 : lats[[(p / 100.0 * (lats.size - 1)).round, lats.size - 1].min] }
puts "reqs=#{total_ok} bad=#{bad.sum} secs=#{DURATION.round(1)} rps=#{(total_ok / DURATION).round(1)} " \
     "p50=#{pct.call(50).round(2)} p99=#{pct.call(99).round(2)}"
