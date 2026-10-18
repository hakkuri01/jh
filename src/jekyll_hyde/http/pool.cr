require "./client"

module JekyllHyde::Http
  # One pool result: the path requested, and its Outcome or an error message. An
  # error is counted, not fatal; a scan continues past a dead URL.
  record Job, path : String, outcome : Outcome?, error : String?

  # Dispatches many GETs over a fixed pool of C fibers against one origin, each
  # fiber reusing its own keep-alive Client. At most C requests are in flight,
  # and the paths are iterated once, never rescanned (AGENTS Big O, dispatch).
  class Pool
    @concurrency : Int32
    # How often a paused feed wakes to recheck the pause and cancel flags.
    PAUSE_POLL = 40.milliseconds

    def initialize(@base : String, @options : Options = Options.new, concurrency : Int32 = 40)
      @concurrency = Math.max(concurrency, 1)
    end

    # Run every path in *paths*, yielding each Job as it completes (completion
    # order, not input order; each Job carries its own path). Stops feeding new
    # paths once *cancel* returns true, so a cancelled scan drains the at-most-C
    # in-flight requests and returns rather than running the list to the end.
    # While *pause* returns true the feed holds (no new requests go out, in-flight
    # ones drain), resuming when it clears; cancel still breaks a paused feed.
    def run(paths : Enumerable(String), cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, &) : Nil
      jobs = Channel(String).new(@concurrency)
      results = Channel(Job).new(@concurrency)
      done = Channel(Nil).new

      @concurrency.times do
        spawn do
          work(jobs, results)
          done.send(nil)
        end
      end
      spawn feed(paths, jobs, cancel, pause)
      spawn close_when_drained(done, results)

      while job = results.receive?
        yield job
      end
    end

    private def feed(paths : Enumerable(String), jobs : Channel(String), cancel : Proc(Bool)?, pause : Proc(Bool)?) : Nil
      paths.each do |path|
        while pause.try(&.call) && !cancel.try(&.call)
          sleep(PAUSE_POLL)
        end
        break if cancel.try(&.call)
        jobs.send(path)
      end
      jobs.close
    end

    private def close_when_drained(done : Channel(Nil), results : Channel(Job)) : Nil
      @concurrency.times { done.receive }
      results.close
    end

    # A pool worker: its own keep-alive client, reused across the jobs it pulls.
    # Nothing escapes the fiber. A client that cannot be built for the origin (a
    # malformed base URL, say) and any per-request failure both become errored
    # jobs, never an unhandled spawn exception that would corrupt the TUI.
    private def work(jobs : Channel(String), results : Channel(Job)) : Nil
      client = build_client
      while path = jobs.receive?
        results.send(fetch_job(client, path))
      end
    end

    private def build_client : Client?
      Client.new(@base, @options)
    rescue
      nil
    end

    private def fetch_job(client : Client?, path : String) : Job
      return Job.new(path, nil, "unreachable origin") unless client
      Job.new(path, client.fetch(path), nil)
    rescue ex : Error
      Job.new(path, nil, ex.message)
    end
  end
end
