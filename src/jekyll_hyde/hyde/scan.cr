require "uri"
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
  # and a depth bound. The target's own path is the scan root ("/app" scans under
  # "/app/", not a reset to "/"), and depth is measured relative to it, matching
  # feroxbuster. Each directory is calibrated (its wildcard filters accumulate,
  # keyed by status), then every wordlist entry is requested under it; each kept
  # response's body is mined for links, and any link is requested too, so
  # discovery follows the site's own structure, not just the wordlist. A kept
  # directory-looking hit (3xx to url + /, or 2xx/403 ending in /) is queued as a
  # child unless already seen or past the depth. Recursion and extraction are on
  # by default, which is Hyde's whole point. Directories are walked one at a time;
  # the URL set is what matters, and cross-directory concurrency is throughput.
  # The crawl is budgeted so a hostile target cannot drive it unbounded. One run
  # per instance.
  class Scan
    # Crawl budget (AGENTS Big O 6): a hostile target that emits a fresh unique
    # link per response must not drive unbounded requests, memory, or results.
    # Links past the per-response cap are dropped, and once the frontier reaches
    # the global cap no new path is queued and the walk winds down with one
    # warning. The per-link path depth is deliberately not capped beyond the
    # recursion bound: feroxbuster requests extracted files at any depth, and the
    # frontier cap already bounds the queue.
    MAX_LINKS_PER_RESPONSE =     500
    MAX_FRONTIER           = 100_000

    @results = Core::Results.new
    @requested = Set(String).new
    @queue = Deque(String).new
    @seen = Set(String).new
    @filters = Hash(Int32, Array(WildcardFilter)).new
    @sim_filters = [] of SimilarityFilter
    @on_result : Proc(Core::Response, Nil)? = nil
    @cancel : Proc(Bool)? = nil
    @pause : Proc(Bool)? = nil
    @origin : String
    @base : String
    @base_depth : Int32
    # Live progress, read by the TUI from another fiber. Safe under the
    # single-thread scheduler: written on the scan fiber, read on the UI fiber,
    # both only at yield points, and a plain Int32 read never tears.
    getter completed = 0
    getter errors = 0
    # Set once if the frontier cap is hit, surfaced in the dashboard footer.
    getter warning : String? = nil

    def initialize(target : String, @wordlist : Wordlist::List, @options : Http::Options = Http::Options.hyde, *, concurrency : Int32 = 40, @max_depth : Int32 = 4, auto_tune : Bool = false, @max_frontier : Int32 = MAX_FRONTIER)
      uri = URI.parse(target)
      # Origin is scheme://host[:port] only; the path becomes the scan's base
      # directory. The stdlib HTTP::Client keeps only host+port anyway, so paths
      # must be requested explicitly, and the base is where that request line
      # starts.
      @origin = origin_of(uri)
      @base = base_path(uri.path)
      @base_depth = depth(@base)
      @extractor = Extractor.new(@origin)
      @tuner = Tuner.new(concurrency, enabled: auto_tune)
    end

    private def origin_of(uri : URI) : String
      host = uri.host || ""
      (port = uri.port) ? "#{uri.scheme}://#{host}:#{port}" : "#{uri.scheme}://#{host}"
    end

    # The scan's root directory: the target's own path as a directory ("/app" ->
    # "/app/"), or "/" when the target names no path. Every queued path hangs off
    # this, so a target subpath is honored, not silently reset to root.
    private def base_path(path : String) : String
      return "/" if path.empty? || path == "/"
      path.ends_with?("/") ? path : "#{path}/"
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
      enqueue_dir(@base)
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
      seed_robots(worklist) if dir == @base
      drain(worklist)
    end

    private def learn_filters(dir : String) : Nil
      learned = Calibration.new(@origin + dir, @options).learn
      learned.wildcards.each do |filter|
        bucket = (@filters[filter.status] ||= [] of WildcardFilter)
        bucket << filter unless bucket.includes?(filter)
      end
      learned.similarities.each { |filter| @sim_filters << filter unless @sim_filters.includes?(filter) }
    end

    # robots.txt is requested once, from the root, and its Allow/Disallow paths
    # are fed in like any other extracted links. Always a GET (operator -X does
    # not apply to this metadata fetch), with the operator's headers.
    private def seed_robots(worklist : Deque(String)) : Nil
      request = Http::Request.new("GET", "/robots.txt", Http::Request.headers_from(@options.headers))
      outcome = Http::Client.new(@origin, @options).fetch(request)
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
      return if wildcard_filtered?(response)
      return if sim_filtered?(outcome.body)
      @results << response
      @on_result.try &.call(response)
      mine_links(outcome.body, job.path, worklist)
      recurse(job.path, outcome)
    end

    # Drop a response that matches a learned wildcard fingerprint for its own
    # status: an O(1) status lookup, then at most the few filters that share that
    # status, not every filter learned across the walk (AGENTS Big O,
    # per-response filter).
    private def wildcard_filtered?(response : Core::Response) : Bool
      bucket = @filters[response.status]?
      return false unless bucket
      bucket.any?(&.matches?(response))
    end

    # Mine the kept body for links, capped per response so one hostile page
    # cannot enqueue an unbounded batch (AGENTS Big O 6, text-from-outside).
    private def mine_links(body : Bytes, from : String, worklist : Deque(String)) : Nil
      @extractor.extract(decode(body), from).each_with_index do |link, index|
        break if index >= MAX_LINKS_PER_RESPONSE
        offer(link, worklist)
      end
    end

    # SimHash fallback: drop a response that is a near-duplicate of a learned
    # soft-404. One O(body) pass, taken only once a filter exists (AGENTS Big O,
    # text-from-outside).
    private def sim_filtered?(body : Bytes) : Bool
      return false if @sim_filters.empty?
      signature = SimHash.signature(decode(body))
      @sim_filters.any?(&.matches?(signature))
    end

    # Queue *path* unless already requested or the frontier is full. The global
    # cap is the hard stop on a hostile fresh-link chain (AGENTS Big O 6).
    private def offer(path : String, worklist : Deque(String)) : Nil
      if @requested.size >= @max_frontier
        @warning ||= "crawl limit reached (#{@max_frontier} paths); discovery stopped"
        return
      end
      worklist.push(path) if @requested.add?(path)
    end

    private def recurse(path : String, outcome : Http::Outcome) : Nil
      return unless directory?(path, outcome)
      child = path.ends_with?("/") ? path : "#{path}/"
      return if @max_depth != 0 && (depth(child) - @base_depth) >= @max_depth
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
