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

deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DURATION
ok = Array.new(CONC, 0)
bad = Array.new(CONC, 0)

threads = CONC.times.map do |i|
  Thread.new do
    conn = Net::HTTP.new(HOST, PORT); conn.read_timeout = 60
    conn.start
    req = Net::HTTP::Get.new(ENDPOINT); req["User-Agent"] = UA; req["Cookie"] = COOKIE
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        r = conn.request(req)
        r.code.to_i == 200 ? ok[i] += 1 : bad[i] += 1
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
puts "reqs=#{total_ok} bad=#{bad.sum} secs=#{DURATION.round(1)} rps=#{(total_ok / DURATION).round(1)}"
