threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

rails_env = ENV.fetch("RAILS_ENV", "development")
environment rails_env

case rails_env
when "production"
  if (puma_workers = ENV.fetch("PUMA_WORKERS", "0").to_i) > 0
    # Clustered baseline for the memory-saturation benchmark (normal app, i.e.
    # RACTOR_MODE=0): N forked worker processes with copy-on-write preload --
    # the traditional way to use N cores on CRuby. Compared against a single-
    # process Ractor pool (RACTOR_POOL=N) serving the same concurrency.
    workers puma_workers
    preload_app!
  end
  # Otherwise: Ractor-safety experiment runs in single mode (no forked workers,
  # no preload). ractorize! sets up the Ractor query-dispatch executor and the
  # Ractor-safe logger's consumer thread in this process; those threads would
  # not survive Puma's fork, so a clustered worker would deadlock on the first
  # request that dispatches to the main Ractor.
when "development"
  worker_timeout 3600 # Don't let worker die during debugger session
end

port ENV.fetch("PORT", 3000)
plugin :tmp_restart
