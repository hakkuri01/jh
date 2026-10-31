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
  # "/app/", not a reset to "/"), and depth is measured relative to it, so -d
  # means the same thing whether the target names a host root or a subdirectory. Each directory is calibrated (its wildcard filters accumulate,
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
    # Discovered-link budget (AGENTS Big O 6): a hostile target that emits fresh
    # unique links per response must not drive unbounded requests. Links mined
    # from bodies and robots.txt count against MAX_FRONTIER; once it is reached no
    # new discovered path is queued and the walk winds down with one warning. The
    # operator's own wordlist is NOT counted: it is a bounded input they chose,
    # where the budget exists to stop a server inventing paths, so counting it
    # would silently truncate the scan that was asked for. The per-response link
    # cap and the per-link byte cap live in the Extractor.
    MAX_FRONTIER = 100_000

    @results = Core::Results.new
    @requested = Set(String).new
    @discovered = 0
    @queue = Deque(String).new
    @seen = Set(String).new
    @filters = Hash(Int32, Array(WildcardFilter)).new
    @sim_filters = [] of SimilarityFilter
    @on_result : Proc(Core::Response, Nil)? = nil
    @cancel : Proc(Bool)? = nil
    @pause : Proc(Bool)? = nil
    @origin : String
    @origin_normalized : String
    @base : String
    @base_depth : Int32
    # Live progress, read by the TUI from another fiber. Safe under the
    # single-thread scheduler: written on the scan fiber, read on the UI fiber,
    # both only at yield points, and a plain Int32 read never tears.
    getter completed = 0
    getter errors = 0
    # Set once if the frontier cap is hit, surfaced in the dashboard footer.
    getter warning : String? = nil

    def initialize(target : String, @wordlist : Wordlist::List, @options : Http::Options = Http::Options.hyde, *, concurrency : Int32 = 40, @max_depth : Int32 = 4, auto_tune : Bool = false, @similar_to : Array(String) = [] of String, @max_frontier : Int32 = MAX_FRONTIER)
      uri = URI.parse(target)
      # Origin is scheme://host[:port] only; the path becomes the scan's base
      # directory. The stdlib HTTP::Client keeps only host+port anyway, so paths
      # must be requested explicitly, and the base is where that request line
      # starts.
      @origin = origin_of(uri)
      @origin_normalized = origin_of(uri.normalize)
      @base = base_path(uri.path)
      @base_depth = depth(@base)
      @concurrency = concurrency
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

    # Stream each kept result to *on_result* as found, stopping when *cancel* turns
    # true and holding while *pause* does. Both are checked before each directory
    # and batch, so a stop or hold takes effect within one pool of in-flight requests.
    def run(cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, &on_result : Core::Response ->) : Core::Results
      @on_result = on_result
      @cancel = cancel
      @pause = pause
      perform
    end

    private def perform : Core::Results
      seed_similarity_filters
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
      @wordlist.entries.each { |word| offer(dir + Http.request_token(word), worklist) }
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
      @extractor.extract_robots(decode(outcome.body)).each { |link| offer_discovered(link, worklist) }
    rescue Http::Error
      # no reachable robots.txt, nothing to seed
    end

    # Seed the near-duplicate filters from operator reference pages
    # (--filter-similar-to): fetch each, hash its body, seed the same `@sim_filters`
    # the soft-404 fallback uses. Best effort: an unusable reference is skipped.
    private def seed_similarity_filters : Nil
      @similar_to.each do |url|
        unless Http.valid_url?(url)
          skip_reference
          next
        end
        body = decode(fetch_reference(URI.parse(url)).body)
        if body.empty?
          skip_reference
          next
        end
        filter = SimilarityFilter.from(body)
        @sim_filters << filter unless @sim_filters.includes?(filter)
      rescue Http::Error
        skip_reference
      end
    end

    # Fetch a reference page. Its origin usually matches the scan target, so the
    # operator's auth headers and cookie are sent; a cross-origin reference is
    # fetched WITHOUT them, since credentials supplied for one origin must not be
    # handed to an unrelated host just because a filter flag named it.
    private def fetch_reference(uri : URI) : Http::Outcome
      headers = origin_of(uri) == @origin ? Http::Request.headers_from(@options.headers) : HTTP::Headers.new
      request = Http::Request.new("GET", uri.request_target, headers)
      Http::Client.new(origin_of(uri), @options).fetch(request)
    end

    private def skip_reference : Nil
      @warning ||= "a --filter-similar-to reference could not be used; its filter was skipped"
    end

    private def drain(worklist : Deque(String)) : Nil
      until worklist.empty? || cancelled?
        batch = worklist.to_a
        worklist.clear
        # The pool reads the tuned concurrency live, so --auto-tune backs off
        # inside this batch: the root batch is the whole wordlist, so waiting for
        # a boundary would apply the limit only after most of the scan had run.
        Http::Pool.new(@origin, @options, @concurrency).run(batch, @cancel, @pause, limit: -> { @tuner.concurrency }) { |job| handle(job, worklist) }
      end
    end

    private def handle(job : Http::Job, worklist : Deque(String)) : Nil
      outcome = job.outcome
      @completed += 1
      @errors += 1 unless outcome
      @tuner.observe(outcome ? outcome.status : 0, error: outcome.nil?)
      return unless outcome
      text = decode(outcome.body)
      response = Core::Response.hyde(@origin + job.path, outcome.status, outcome.body, outcome.location, text: text)
      # Recurse before filtering: the keep/drop filter answers "is this response
      # worth reporting", recursion answers "is this a directory worth
      # descending". A directory serving a soft-404-shaped body is still a
      # directory, so conflating the two questions loses its children.
      recurse(job.path, outcome)
      return if wildcard_filtered?(response)
      return if sim_filtered?(text)
      @results << response
      @on_result.try &.call(response)
      mine_links(text, job.path, worklist)
    end

    # Drop a response that matches a learned wildcard fingerprint for its status:
    # an O(1) status lookup, then the filters sharing that status, not every one
    # learned across the walk (AGENTS Big O, per-response filter).
    private def wildcard_filtered?(response : Core::Response) : Bool
      bucket = @filters[response.status]?
      return false unless bucket
      bucket.any?(&.matches?(response))
    end

    # Mine the kept body for links; the Extractor caps how many it returns, and
    # each is offered against the discovered-link budget (AGENTS Big O 6).
    private def mine_links(text : String, from : String, worklist : Deque(String)) : Nil
      @extractor.extract(text, from).each { |link| offer_discovered(link, worklist) }
    end

    # SimHash fallback: drop a response that is a near-duplicate of a learned
    # soft-404. One pass over the already-decoded text, taken only once a filter
    # exists (AGENTS Big O, text-from-outside).
    private def sim_filtered?(text : String) : Bool
      return false if @sim_filters.empty?
      signature = SimHash.signature(text)
      @sim_filters.any?(&.matches?(signature))
    end

    # Queue an operator or structural path (the directory itself, a wordlist
    # entry): deduplicated, never counted against the discovered-link budget, so a
    # large wordlist is scanned in full rather than truncated.
    # ponytail: @requested therefore grows with W x in-scope directories, bounded
    # by the operator's own list and the depth-bounded seen-URL set, not by the
    # network. A list too large to dedup in memory would need a streamed set.
    private def offer(path : String, worklist : Deque(String)) : Nil
      worklist.push(path) if @requested.add?(path)
    end

    # Queue a page-authored path (a mined link, a robots.txt entry): deduplicated
    # and counted against the discovered-link budget, the hard stop on a hostile
    # fresh-link chain (AGENTS Big O 6). A repeat consumes no budget.
    private def offer_discovered(path : String, worklist : Deque(String)) : Nil
      return if @requested.includes?(path)
      if @discovered >= @max_frontier
        @warning ||= "crawl limit reached (#{@max_frontier} discovered paths); link discovery stopped"
        return
      end
      @requested.add(path)
      @discovered += 1
      worklist.push(path)
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
        directory_redirect?(path, location)
      elsif (200 <= status < 300) || status == 403
        path.ends_with?("/")
      else
        false
      end
    end

    # A 3xx is a directory when its Location resolves, against the requested URL,
    # to that same URL plus a trailing slash on the same origin. Resolving covers
    # the relative, root-relative, and absolute forms; a string compare covers one.
    private def directory_redirect?(path : String, location : String) : Bool
      target = URI.parse(@origin + path).resolve(location).normalize
      origin_of(target) == @origin_normalized && target.path == "#{path}/"
    rescue
      false
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
