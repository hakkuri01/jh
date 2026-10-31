require "option_parser"
require "./scan_config"
require "./headless"
require "./view/app"
require "./jekyll/rule"
require "./jekyll/rules"
require "./jekyll/input"

module JekyllHyde
  # The command-line front door. With no arguments jh opens the composer; with a
  # full command it parses and validates the flags here, then either runs the
  # scan headless (`--headless`: no terminal, results to -o or stdout) or launches
  # the same TUI straight onto the running dashboard (the power-user override),
  # skipping the opener and the form. The engine is built once in ScanBuilder, so
  # the TUI and headless paths cannot drift. A parse or validation problem prints
  # one actionable line and exits non-zero before anything launches. `run` returns
  # the process exit code.
  class Entry
    # The HTTP methods `-X` accepts; anything else is refused before launch.
    METHODS = %w[GET HEAD POST PUT DELETE OPTIONS PATCH]

    def self.run(argv : Array(String), io : IO = STDOUT, err : IO = STDERR) : Int32
      new(io, err).run(argv)
    end

    def initialize(@io : IO, @err : IO = STDERR)
    end

    def run(argv : Array(String)) : Int32
      parser, config, help = parse(argv)
      if help
        @io.puts parser
        return 0
      end
      if problem = validate(config)
        @err.puts "error: #{problem}"
        return 2
      end
      return Headless.run(config, @io, @err) if config.headless?
      unless @io.tty? && STDIN.tty?
        @err.puts "error: jh needs an interactive terminal; give it no arguments to compose a scan, a full command to run one, or add --headless to run without a terminal"
        return 2
      end
      View::App.launch(config, @io)
      0
    rescue ex : ArgumentError
      @err.puts "error: #{ex.message}"
      2
    end

    # Parse argv into a config, folding in the mode and every flag as the handlers
    # fire. Returns the parser (for help text), the config, and whether help was
    # asked. Raises ArgumentError on an unknown option or bad value, caught by `run`.
    def parse(argv : Array(String)) : {OptionParser, ScanConfig, Bool}
      config = ScanConfig.new
      help = false
      parser = OptionParser.new do |p|
        p.banner = "usage: jh [--hyde | --jekyll] -u URL -w WORDLIST [options]"
        common_flags(p, config)
        jekyll_flags(p, config)
        hyde_flags(p, config)
        p.on("-h", "--help", "show this help") { help = true }
        p.invalid_option { |flag| raise ArgumentError.new("unknown option #{flag}") }
      end
      parser.parse(argv)
      imply_post(config)
      {parser, config, help}
    end

    # ffuf/feroxbuster "copy as curl" convenience: a request body with the method
    # still at its GET default implies POST, so `--data` alone posts. An explicit
    # `-X` wins, since it is no longer the default by the time this runs.
    private def imply_post(c : ScanConfig) : Nil
      body = c.body
      c.method = "POST" if body && !body.empty? && c.method == "GET"
    end

    # An integer flag value, refused with one actionable line rather than silently
    # kept as the default (ffuf and feroxbuster both reject a non-numeric value).
    private def int_flag(value : String, flag : String) : Int32
      value.to_i? || raise ArgumentError.new("#{flag} needs a whole number")
    end

    # Flags shared by both modes.
    private def common_flags(p : OptionParser, c : ScanConfig) : Nil
      p.on("--hyde", "recursive discovery") { c.mode = "HYDE"; c.mode_set = true }
      p.on("--jekyll", "templated FUZZ fuzzing") { c.mode = "JEKYLL"; c.mode_set = true }
      p.on("-u URL", "--url=URL", "target URL (FUZZ marks the Jekyll injection point)") { |v| c.url = v }
      p.on("-w FILE", "--wordlist=FILE", "wordlist path (repeatable; FILE:KEYWORD for Jekyll input)") { |v| c.wordlists << v }
      p.on("-e LIST", "--extensions=LIST", "extensions to append, e.g. php,html") { |v| c.extensions = v.split(',').map(&.strip).reject(&.empty?) }
      p.on("-t N", "--threads=N", "concurrent requests (default 40)") { |v| c.threads = int_flag(v, "-t") }
      p.on("-k", "--insecure", "skip TLS certificate verification") { c.insecure = true }
      p.on("-X METHOD", "--method=METHOD", "HTTP request method (default GET)") { |v| c.method = v.strip.upcase }
      p.on("-H LINE", "--header=LINE", "request header 'Name: Value' (repeatable)") { |v| c.headers << v }
      p.on("-b COOKIE", "--cookie=COOKIE", "Cookie header value") { |v| c.cookie = v }
      p.on("--data DATA", "request body, FUZZ-able in Jekyll (implies POST)") { |v| c.body = v }
      p.on("-o FILE", "--output=FILE", "write results to FILE on completion") { |v| c.output = v }
      p.on("--format FMT", "export format: json or csv (default json)") { |v| c.format = v }
      p.on("--headless", "run without the TUI; results to -o or stdout, progress on stderr") { c.headless = true }
    end

    # Jekyll's matcher/filter grammar (one letter per metric), the combination
    # modes, the input mode, and autocalibration.
    private def jekyll_flags(p : OptionParser, c : ScanConfig) : Nil
      metric_rule(p, c, "c", "status")
      metric_rule(p, c, "s", "size")
      metric_rule(p, c, "w", "word")
      metric_rule(p, c, "l", "line")
      metric_rule(p, c, "r", "regex")
      metric_rule(p, c, "t", "time")
      p.on("--mmode MODE", "matcher mode: and or or (Jekyll)") do |v|
        c.matcher_mode = Jekyll::Rules::Mode.parse(v)
        c.jekyll_used = true
      end
      p.on("--fmode MODE", "filter mode: and or or (Jekyll)") do |v|
        c.filter_mode = Jekyll::Rules::Mode.parse(v)
        c.jekyll_used = true
      end
      p.on("--mode MODE", "input mode: clusterbomb or pitchfork (Jekyll)") do |v|
        c.input_mode = Jekyll::Input::Mode.parse(v)
        c.jekyll_used = true
      end
      p.on("--ac", "autocalibrate wildcard filters (Jekyll)") do
        c.calibrate = true
        c.jekyll_used = true
      end
    end

    # Register the `--m<letter>` matcher and `--f<letter>` filter for one metric.
    private def metric_rule(p : OptionParser, c : ScanConfig, letter : String, type : String) : Nil
      p.on("--m#{letter} VALUE", "match #{type} (Jekyll)") do |v|
        c.matchers << Jekyll::Rule.build(type, v)
        c.jekyll_used = true
      end
      p.on("--f#{letter} VALUE", "filter #{type} (Jekyll)") do |v|
        c.filters << Jekyll::Rule.build(type, v)
        c.jekyll_used = true
      end
    end

    # Hyde's depth bound and opt-in behaviors.
    private def hyde_flags(p : OptionParser, c : ScanConfig) : Nil
      p.on("-d N", "--depth=N", "max recursion depth (default 4, Hyde; 0 = unlimited)") { |v| c.depth = int_flag(v, "-d") }
      p.on("--no-recursion", "scan only the target, no descent (Hyde)") do
        c.no_recursion = true
        c.hyde_used = true
      end
      p.on("--auto-tune", "back off concurrency on 429/403 floods (Hyde)") do
        c.auto_tune = true
        c.hyde_used = true
      end
      p.on("--filter-similar-to URL", "drop pages similar to URL, e.g. a soft 404 (Hyde, repeatable)") do |v|
        c.filter_similar << v
        c.hyde_used = true
      end
    end

    # Whether the parsed command is runnable. A mode is mandatory (a command
    # launches straight into the scan), and a mode-specific flag used against the
    # wrong engine is rejected rather than silently ignored.
    private def validate(c : ScanConfig) : String?
      return "pick a mode: --hyde or --jekyll" unless c.mode_set?
      return "a target URL is required (-u)" if c.url.empty?
      return "a wordlist is required (-w)" if c.wordlists.empty?
      return "recursion depth (-d) cannot be negative; use 0 for unlimited" if c.depth < 0
      wrong_mode_flag(c) || bad_method(c) || bad_header(c) || missing_fuzz(c) || bad_format(c)
    end

    # The request method must be one jh can send, unless it is a Jekyll template
    # carrying a bound keyword (ffuf fuzzes the method too): that resolves per
    # request, so the allowlist (a typo guard) only judges a static method.
    private def bad_method(c : ScanConfig) : String?
      return nil if c.mode == "JEKYLL" && keywords(c).any? { |keyword| c.method.includes?(keyword) }
      "method must be one of #{METHODS.join(", ")}" unless METHODS.includes?(c.method)
    end

    # Each -H must look like a header line so it can be parsed and sent. The bad
    # line is NOT echoed: a malformed auth header would otherwise leak its token
    # into the diagnostics (AGENTS secret-handling).
    private def bad_header(c : ScanConfig) : String?
      c.headers.each do |line|
        return "a header must look like 'Name: Value'" unless line.includes?(':')
      end
      nil
    end

    # A mode-specific flag used against the other engine.
    private def wrong_mode_flag(c : ScanConfig) : String?
      return "the matcher, filter, and input flags are Jekyll-only (use --jekyll)" if c.mode == "HYDE" && c.jekyll_used?
      return "--no-recursion, --auto-tune, and --filter-similar-to are Hyde-only (use --hyde)" if c.mode == "JEKYLL" && c.hyde_used?
      nil
    end

    # A Jekyll command whose URL is missing a bound keyword.
    private def missing_fuzz(c : ScanConfig) : String?
      return nil unless c.mode == "JEKYLL"
      if missing = missing_keyword(c)
        "Jekyll needs the #{missing} keyword somewhere in the request (the URL, a header, the cookie, the method, or the body)"
      end
    end

    private def bad_format(c : ScanConfig) : String?
      return "export format must be json or csv" if (c.output || c.headless?) && c.format != "json" && c.format != "csv"
      nil
    end

    # The first bound keyword absent from every request part, or nil when each
    # appears somewhere (the URL, a header, the cookie, the method, or the body).
    # ffuf lets FUZZ live in any part, so a body-only keyword is valid.
    private def missing_keyword(c : ScanConfig) : String?
      parts = [c.url, c.method, c.cookie || "", c.body || ""] + c.headers
      keywords(c).find { |keyword| parts.none?(&.includes?(keyword)) }
    end

    # The bound keyword of each -w spec (a bare path defaults to FUZZ).
    private def keywords(c : ScanConfig) : Array(String)
      c.wordlists.map { |spec| Jekyll::Source.split(spec)[1] }
    end
  end
end
