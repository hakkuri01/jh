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

    # Caps the requests running at once, read live from *limit*, so Hyde's
    # auto-tuner can lower concurrency mid-batch (and raise it back) without the
    # pool being torn down. A worker acquires before each fetch and releases
    # after; with no *limit* (Jekyll, no auto-tune) it never waits.
    # ponytail: a 2ms poll, not a condition variable. It engages only while
    # throttled below the worker ceiling, where going gently is the point, and n
    # is bounded by C (ScanConfig::MAX_THREADS, 1000). At the ceiling a releasing
    # worker always leaves a slot free before it re-acquires, so it never polls.
    private class Limiter
      POLL = 2.milliseconds

      def initialize(@limit : Proc(Int32)?)
        @in_flight = 0
      end

      def acquire : Nil
        limit = @limit
        return unless limit
        while @in_flight >= limit.call
          sleep(POLL)
        end
        @in_flight += 1
      end

      def release : Nil
        @in_flight -= 1 if @limit
      end
    end

    def initialize(@base : String, @options : Options = Options.new, concurrency : Int32 = 40)
      @concurrency = Math.max(concurrency, 1)
      @base_headers = Request.headers_from(@options.headers)
    end

    # Lazily wraps bare paths as Requests with one static method, header set, and
    # body, so the String overload stays O(1) in space over a huge path stream.
    private struct PathRequests
      include Enumerable(Request)

      def initialize(@paths : Enumerable(String), @method : String, @headers : HTTP::Headers, @body : String? = nil)
      end

      def each(& : Request ->) : Nil
        @paths.each { |path| yield Request.new(@method, path, @headers, @body) }
      end
    end

    # Run every path in *paths* with the options' static method, headers, and body.
    def run(paths : Enumerable(String), cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, limit : Proc(Int32)? = nil, &) : Nil
      run(PathRequests.new(paths, @options.method, @base_headers, @options.body), cancel, pause, limit) { |job| yield job }
    end

    # Run every request, yielding each Job as it completes (completion order, each
    # Job carrying its path). *cancel* stops the feed and drains the at-most-C
    # in-flight requests; *pause* holds the feed (in-flight ones drain) and resumes
    # when it clears, with cancel still breaking a paused feed.
    def run(requests : Enumerable(Request), cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, limit : Proc(Int32)? = nil, &) : Nil
      jobs = Channel(Request).new(@concurrency)
      results = Channel(Job).new(@concurrency)
      done = Channel(Nil).new
      limiter = Limiter.new(limit)
      producer_error = nil
      # Set when the consumer (the yielded block) stops early, so the feed winds
      # down even if the caller's own cancel never turns true.
      stopped = false
      feed_cancel = -> { stopped || (cancel.try(&.call) || false) }

      spawn_workers(jobs, results, done, limiter)
      # A request the producer fails to build (e.g. an invalid FUZZ header) is
      # captured and re-raised after the pool drains, so the scan ends with one
      # actionable error, not a hang on a feed fiber that died before closing jobs.
      spawn do
        feed(requests, jobs, feed_cancel, pause)
      rescue ex
        producer_error = ex
      ensure
        jobs.close
      end
      spawn close_when_drained(done, results)

      begin
        while job = results.receive?
          yield job
        end
      rescue ex
        # The consumer stopped early (cancel closed the TUI's result channel).
        # Drain so the parked workers free their sockets; swallow a cancel
        # teardown, re-raise any other consumer failure (F-19).
        stopped = true
        drain_results(results)
        raise ex unless cancel.try(&.call)
      end
      if error = producer_error
        raise error
      end
    end

    private def spawn_workers(jobs : Channel(Request), results : Channel(Job), done : Channel(Nil), limiter : Limiter) : Nil
      @concurrency.times do
        spawn do
          work(jobs, results, limiter)
          done.send(nil)
        end
      end
    end

    # After the consumer stops early its in-flight workers are parked sending to a
    # results channel nobody reads; draining lets each finish its request, free its
    # socket, and exit instead of parking for the process lifetime (F-19).
    private def drain_results(results : Channel(Job)) : Nil
      while results.receive?
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
    end

    private def close_when_drained(done : Channel(Nil), results : Channel(Job)) : Nil
      @concurrency.times { done.receive }
      results.close
    end

    # A pool worker: its own keep-alive client, reused across jobs. A client that
    # cannot be built and any per-request failure become errored jobs, never an
    # unhandled spawn exception that would corrupt the TUI. The limiter gates each
    # fetch to the live concurrency; the permit covers the fetch, not the send.
    private def work(jobs : Channel(Request), results : Channel(Job), limiter : Limiter) : Nil
      client = build_client
      while request = jobs.receive?
        limiter.acquire
        job = begin
          fetch_job(client, request)
        ensure
          limiter.release
        end
        results.send(job)
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
