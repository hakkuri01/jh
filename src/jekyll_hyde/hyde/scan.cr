require "../core/results"
require "../core/response"
require "../http/client"
require "../http/pool"
require "../wordlist/list"
require "./calibration"
require "./extractor"
require "./sim_hash"
require "./similarity_filter"
require "./tuner"
require "./wildcard_filter"

module JekyllHyde::Hyde
  # Recursive discovery: a breadth-first walk of directories with a seen-URL set
  # and a depth bound. Each directory is calibrated (its wildcard filters
  # accumulate globally), then every wordlist entry is requested under it; each
  # kept response's body is mined for links, and any link is requested too, so
  # discovery follows the site's own structure, not just the wordlist. A kept
  # directory-looking hit (3xx to url + /, or 2xx/403 ending in /) is queued as a
  # child unless already seen or past the depth. Recursion and extraction are on
  # by default, which is Hyde's whole point. Directories are walked one at a time;
  # the URL set is what matters, and cross-directory concurrency is throughput.
  # One run per instance.
  class Scan
    @results = Core::Results.new
    @requested = Set(String).new
    @queue = Deque(String).new
    @seen = Set(String).new
    @filters = [] of WildcardFilter
    @sim_filters = [] of SimilarityFilter
    @on_result : Proc(Core::Response, Nil)? = nil
    @cancel : Proc(Bool)? = nil
    @pause : Proc(Bool)? = nil
    # Live progress, read by the TUI from another fiber. Safe under the
    # single-thread scheduler: written on the scan fiber, read on the UI fiber,
    # both only at yield points, and a plain Int32 read never tears.
    getter completed = 0
    getter errors = 0

    def initialize(origin : String, @wordlist : Wordlist::List, @options : Http::Options = Http::Options.hyde, *, concurrency : Int32 = 40, @max_depth : Int32 = 4, auto_tune : Bool = false)
      # Strip a trailing slash so origin + an absolute path ("/admin") cannot form
      # a double slash; every queued path already starts with "/".
      @origin = origin.rstrip('/')
      @extractor = Extractor.new(@origin)
      @tuner = Tuner.new(concurrency, enabled: auto_tune)
    end

    # Run to completion, returning every kept result.
    def run : Core::Results
      perform
    end

    # Stream each kept result to *on_result* as it is found, stopping early when
    # *cancel* returns true and holding while *pause* returns true. Cancellation
    # is checked before each directory and request batch, so a stop takes effect
    # within one pool of in-flight requests: the TUI streams results into the Elm
    # loop, q stops the scan, and p holds it without leaving requests hammering
    # the target.
    def run(cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, &on_result : Core::Response ->) : Core::Results
      @on_result = on_result
      @cancel = cancel
      @pause = pause
      perform
    end

    private def perform : Core::Results
      enqueue_dir("/")
      until @queue.empty? || cancelled?
        scan_directory(@queue.shift)
      end
      @results
    end

    private def cancelled? : Bool
      @cancel.try(&.call) || false
    end

    private def scan_directory(dir : String) : Nil
      learn_filters(dir)
      worklist = Deque(String).new
      offer(dir, worklist) # the directory's own URL, reported as a finding
      @wordlist.entries.each { |word| offer(dir + word, worklist) }
      seed_robots(worklist) if dir == "/"
      drain(worklist)
    end

    private def learn_filters(dir : String) : Nil
      learned = Calibration.new(@origin + dir, @options).learn
      learned.wildcards.each { |filter| @filters << filter unless @filters.includes?(filter) }
      learned.similarities.each { |filter| @sim_filters << filter unless @sim_filters.includes?(filter) }
    end

    # robots.txt is requested once, from the root, and its Allow/Disallow paths
    # are fed in like any other extracted links.
    private def seed_robots(worklist : Deque(String)) : Nil
      outcome = Http::Client.new(@origin, @options).fetch("/robots.txt")
      return if outcome.status >= 400
      @extractor.extract_robots(decode(outcome.body)).each { |link| offer(link, worklist) }
    rescue Http::Error
      # no reachable robots.txt, nothing to seed
    end

    private def drain(worklist : Deque(String)) : Nil
      until worklist.empty? || cancelled?
        batch = worklist.to_a
        worklist.clear
        Http::Pool.new(@origin, @options, @tuner.concurrency).run(batch, @cancel, @pause) { |job| handle(job, worklist) }
      end
    end

    private def handle(job : Http::Job, worklist : Deque(String)) : Nil
      outcome = job.outcome
      @completed += 1
      @errors += 1 unless outcome
      @tuner.observe(outcome ? outcome.status : 0, error: outcome.nil?)
      return unless outcome
      response = Core::Response.hyde(@origin + job.path, outcome.status, outcome.body, outcome.location)
      return if @filters.any?(&.matches?(response))
      return if sim_filtered?(outcome.body)
      @results << response
      @on_result.try &.call(response)
      @extractor.extract(decode(outcome.body), job.path).each { |link| offer(link, worklist) }
      recurse(job.path, outcome)
    end

    # SimHash fallback: drop a response that is a near-duplicate of a learned
    # soft-404. One O(body) pass, taken only once a filter exists (AGENTS Big O,
    # text-from-outside).
    private def sim_filtered?(body : Bytes) : Bool
      return false if @sim_filters.empty?
      signature = SimHash.signature(decode(body))
      @sim_filters.any?(&.matches?(signature))
    end

    private def offer(path : String, worklist : Deque(String)) : Nil
      worklist.push(path) if @requested.add?(path)
    end

    private def recurse(path : String, outcome : Http::Outcome) : Nil
      return unless directory?(path, outcome)
      child = path.ends_with?("/") ? path : "#{path}/"
      return if @max_depth != 0 && depth(child) >= @max_depth
      enqueue_dir(child)
    end

    private def enqueue_dir(dir : String) : Nil
      @queue.push(dir) if @seen.add?(dir)
    end

    # A directory-looking hit: a 3xx whose Location resolves to url + /, or a
    # 2xx/403 whose url ends in /.
    private def directory?(path : String, outcome : Http::Outcome) : Bool
      status = outcome.status
      if 300 <= status < 400
        location = outcome.location
        return false unless location
        resolved = location.starts_with?(@origin) ? location[@origin.size..] : location
        resolved == "#{path}/"
      elsif (200 <= status < 300) || status == 403
        path.ends_with?("/")
      else
        false
      end
    end

    # Count of non-empty path segments: "/" -> 0, "/a/" -> 1, "/a/b/" -> 2.
    private def depth(path : String) : Int32
      path.split('/').count { |segment| !segment.empty? }
    end

    private def decode(body : Bytes) : String
      String.new(body).scrub
    end
  end
end
