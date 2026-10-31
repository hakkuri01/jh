require "./jekyll/rule"
require "./jekyll/rules"
require "./jekyll/input"

module JekyllHyde
  # A fully described scan: the one currency between the command-line front door
  # and the running engine. The command line fills every field; the cockpit form
  # fills the subset it exposes (url, one wordlist, extensions, threads, depth,
  # and in Jekyll a status matcher and filter) and leaves the rest at their
  # defaults. The parse-tracking predicates (mode_set, jekyll_used, hyde_used)
  # are set only by the CLI parser, which uses them to reject a missing or
  # wrong-mode flag; they stay false for a form-composed scan, which cannot
  # express a wrong-mode flag in the first place.
  class ScanConfig
    # The upper bound on -t: enough for any real scan, low enough that sizing the
    # pool channels and spawning the fibers cannot exhaust memory before a single
    # request goes out. Operator-supplied, so a typo clamps rather than crashes.
    MAX_THREADS = 1000

    property mode = "HYDE"
    property url = ""
    # "-w" specs, each "path" or "path:KEYWORD" (Hyde ignores the keyword).
    property wordlists = [] of String
    property extensions = [] of String
    @threads = 40
    property depth = 4
    property? no_recursion = false
    property? auto_tune = false
    # Hyde: operator-supplied reference pages (--filter-similar-to, repeatable).
    # Each is fetched once and every response that is a near-duplicate of it is
    # dropped, for noise that does not look like a soft 404.
    property filter_similar = [] of String
    property? insecure = false
    # Operator request shaping: the HTTP method (-X), raw "Name: Value" headers
    # (-H, repeatable), and a cookie (-b). All sent verbatim; in Jekyll each may
    # carry a FUZZ keyword. Headers and cookie are kept out of Core::Response and
    # every export, so supplied auth material never lands in a results file.
    property method = "GET"
    property headers = [] of String
    property cookie : String? = nil
    # Request body (--data): sent verbatim on every request, FUZZ-substituted per
    # combination in Jekyll. Like -H/-b, it is kept out of Core::Response and
    # every export, so a supplied payload never lands in a results file.
    property body : String? = nil
    property matchers = [] of Jekyll::Rule
    property filters = [] of Jekyll::Rule
    property matcher_mode = Jekyll::Rules::Mode::Or
    property filter_mode = Jekyll::Rules::Mode::Or
    property? calibrate = false
    property input_mode = Jekyll::Input::Mode::Clusterbomb
    property output : String? = nil
    property format = "json"
    # Run without the TUI (--headless): results to -o or stdout, progress on
    # stderr, an exit code for chaining. Needs no terminal, for CI and agents.
    property? headless = false
    property? mode_set = false
    property? jekyll_used = false
    property? hyde_used = false

    # Concurrent requests, clamped to [1, MAX_THREADS] on the way in so neither
    # launch path (the form or the command line) can set an out-of-range value.
    def threads : Int32
      @threads
    end

    def threads=(value : Int32) : Int32
      @threads = value.clamp(1, MAX_THREADS)
    end

    # Add a status matcher from a cockpit field. A blank or malformed value is
    # dropped, not raised, so a stray keystroke never aborts a scan; the command
    # line, by contrast, reports a bad value and refuses to launch.
    def match_status(value : String) : Nil
      add_status(@matchers, value)
    end

    def filter_status(value : String) : Nil
      add_status(@filters, value)
    end

    # The raw "Name: Value" header lines the request layer sends: the -H headers
    # with any -b cookie folded in as a Cookie header.
    def request_headers : Array(String)
      cookie = @cookie
      cookie ? @headers + ["Cookie: #{cookie}"] : @headers
    end

    private def add_status(into : Array(Jekyll::Rule), value : String) : Nil
      return if value.strip.empty?
      into << Jekyll::Rule.build("status", value)
    rescue ArgumentError
      # a malformed status list from a form field is dropped, not fatal
    end
  end
end
