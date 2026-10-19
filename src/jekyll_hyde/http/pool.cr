require "./client"
require "./request"

module JekyllHyde::Http
  # One pool result: the path requested, and its Outcome or an error message. An
  # error is counted, not fatal; a scan continues past a dead URL.
  record Job, path : String, outcome : Outcome?, error : String?

  # Dispatches many requests over a fixed pool of C fibers against one origin,
  # each fiber reusing its own keep-alive Client. At most C requests are in
  # flight, and the inputs are iterated once, never rescanned (AGENTS Big O,
  # dispatch). The work unit is an Http::Request so a caller can vary the method
  # and headers per request (Jekyll FUZZ substitution); the String overload wraps
  # bare paths with the options' static method and headers (Hyde, calibration).
  class Pool
    @concurrency : Int32
    @base_headers : HTTP::Headers
    # How often a paused feed wakes to recheck the pause and cancel flags.
    PAUSE_POLL = 40.milliseconds

    def initialize(@base : String, @options : Options = Options.new, concurrency : Int32 = 40)
      @concurrency = Math.max(concurrency, 1)
      @base_headers = Request.headers_from(@options.headers)
    end

    # Lazily wraps bare paths as Requests with one static method and header set,
    # so the String overload stays O(1) in space over a huge path stream.
    private struct PathRequests
      include Enumerable(Request)

      def initialize(@paths : Enumerable(String), @method : String, @headers : HTTP::Headers)
      end

      def each(& : Request ->) : Nil
        @paths.each { |path| yield Request.new(@method, path, @headers) }
      end
    end

    # Run every path in *paths* with the options' static method and headers.
    def run(paths : Enumerable(String), cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, &) : Nil
      run(PathRequests.new(paths, @options.method, @base_headers), cancel, pause) { |job| yield job }
    end

    # Run every request in *requests*, yielding each Job as it completes
    # (completion order, not input order; each Job carries its own path). Stops
    # feeding new requests once *cancel* returns true, so a cancelled scan drains
    # the at-most-C in-flight requests and returns rather than running the list to
    # the end. While *pause* returns true the feed holds (no new requests go out,
    # in-flight ones drain), resuming when it clears; cancel still breaks a paused
    # feed.
    def run(requests : Enumerable(Request), cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, &) : Nil
      jobs = Channel(Request).new(@concurrency)
      results = Channel(Job).new(@concurrency)
      done = Channel(Nil).new

      @concurrency.times do
        spawn do
          work(jobs, results)
          done.send(nil)
        end
      end
      spawn feed(requests, jobs, cancel, pause)
      spawn close_when_drained(done, results)

      while job = results.receive?
        yield job
      end
    end

    private def feed(requests : Enumerable(Request), jobs : Channel(Request), cancel : Proc(Bool)?, pause : Proc(Bool)?) : Nil
      requests.each do |request|
        while pause.try(&.call) && !cancel.try(&.call)
          sleep(PAUSE_POLL)
        end
        break if cancel.try(&.call)
        jobs.send(request)
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
    private def work(jobs : Channel(Request), results : Channel(Job)) : Nil
      client = build_client
      while request = jobs.receive?
        results.send(fetch_job(client, request))
      end
    end

    private def build_client : Client?
      Client.new(@base, @options)
    rescue
      nil
    end

    private def fetch_job(client : Client?, request : Request) : Job
      return Job.new(request.path, nil, "unreachable origin") unless client
      Job.new(request.path, client.fetch(request), nil)
    rescue ex
      # Any per-request failure becomes an errored job, never an unhandled spawn
      # exception: a dead worker fiber would leave the pool's drain blocked.
      Job.new(request.path, nil, ex.message || "request failed")
    end
  end
end
