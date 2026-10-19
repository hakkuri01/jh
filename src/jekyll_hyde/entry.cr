require "option_parser"
require "./scan_config"
require "./view/app"
require "./jekyll/rule"
require "./jekyll/rules"
require "./jekyll/input"

module JekyllHyde
  # The command-line front door. jh is always the interactive program: with no
  # arguments it opens the composer; with a full command it parses and validates
  # the flags here, then launches the same TUI straight onto the running scan
  # dashboard (the power-user override), skipping the opener and the form. There
  # is no headless runner, so there is no second code path to keep in step: the
  # TUI is the program, and a command line is just a pre-filled scan. A parse or
  # validation problem prints one actionable line and exits non-zero before
  # anything launches. `run` returns the process exit code.
  class Entry
    # The HTTP methods `-X` accepts; anything else is refused before launch.
    METHODS = %w[GET HEAD POST PUT DELETE OPTIONS PATCH]

    def self.run(argv : Array(String), io : IO = STDOUT) : Int32
      new(io).run(argv)
    end

    def initialize(@io : IO)
    end

    def run(argv : Array(String)) : Int32
      parser, config, help = parse(argv)
      if help
        @io.puts parser
        return 0
      end
      if problem = validate(config)
        @io.puts "error: #{problem}"
        return 2
      end
      unless @io.tty?
        @io.puts "error: jh runs in an interactive terminal; give it no arguments to compose a scan, or a full command to run one"
        return 2
      end
      View::App.launch(config, @io)
      0
    rescue ex : ArgumentError
      @io.puts "error: #{ex.message}"
      2
    end

    # Parse argv into a config, the chosen mode and every flag folded in as the
    # handlers fire. Returns the parser (for the help text), the config, and
    # whether help was asked. Raises ArgumentError on an unknown option or a
    # malformed flag value, caught by `run`.
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
      {parser, config, help}
    end

    # Flags shared by both modes.
    private def common_flags(p : OptionParser, c : ScanConfig) : Nil
      p.on("--hyde", "recursive discovery") { c.mode = "HYDE"; c.mode_set = true }
      p.on("--jekyll", "templated FUZZ fuzzing") { c.mode = "JEKYLL"; c.mode_set = true }
      p.on("-u URL", "--url=URL", "target URL (FUZZ marks the Jekyll injection point)") { |v| c.url = v }
      p.on("-w FILE", "--wordlist=FILE", "wordlist path (repeatable; FILE:KEYWORD for Jekyll input)") { |v| c.wordlists << v }
      p.on("-e LIST", "--extensions=LIST", "extensions to append, e.g. php,html") { |v| c.extensions = v.split(',').map(&.strip).reject(&.empty?) }
      p.on("-t N", "--threads=N", "concurrent requests (default 40)") { |v| c.threads = v.to_i? || c.threads }
      p.on("-k", "--insecure", "skip TLS certificate verification") { c.insecure = true }
      p.on("-X METHOD", "--method=METHOD", "HTTP request method (default GET)") { |v| c.method = v.strip.upcase }
      p.on("-H LINE", "--header=LINE", "request header 'Name: Value' (repeatable)") { |v| c.headers << v }
      p.on("-b COOKIE", "--cookie=COOKIE", "Cookie header value") { |v| c.cookie = v }
      p.on("-o FILE", "--output=FILE", "write results to FILE on completion") { |v| c.output = v }
      p.on("--format FMT", "export format: json or csv (default json)") { |v| c.format = v }
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
      p.on("-d N", "--depth=N", "max recursion depth (default 4, Hyde)") { |v| c.depth = v.to_i? || c.depth }
      p.on("--no-recursion", "scan only the target, no descent (Hyde)") do
        c.no_recursion = true
        c.hyde_used = true
      end
      p.on("--auto-tune", "back off concurrency on 429/403 floods (Hyde)") do
        c.auto_tune = true
        c.hyde_used = true
      end
    end

    # Whether the parsed command is runnable. A mode is mandatory here: a command
    # launches straight into the scan, so it must say which engine. Mode-specific
    # flags used against the wrong engine are rejected rather than silently
    # ignored.
    private def validate(c : ScanConfig) : String?
      return "pick a mode: --hyde or --jekyll" unless c.mode_set?
      return "a target URL is required (-u)" if c.url.empty?
      return "a wordlist is required (-w)" if c.wordlists.empty?
      wrong_mode_flag(c) || bad_method(c) || bad_header(c) || missing_fuzz(c) || bad_format(c)
    end

    # The request method must be one jh knows how to send.
    private def bad_method(c : ScanConfig) : String?
      "method must be one of #{METHODS.join(", ")}" unless METHODS.includes?(c.method)
    end

    # Each -H must look like a header line so it can be parsed and sent.
    private def bad_header(c : ScanConfig) : String?
      c.headers.each do |line|
        return "a header must look like 'Name: Value': #{line}" unless line.includes?(':')
      end
      nil
    end

    # A mode-specific flag used against the other engine.
    private def wrong_mode_flag(c : ScanConfig) : String?
      return "the matcher, filter, and input flags are Jekyll-only (use --jekyll)" if c.mode == "HYDE" && c.jekyll_used?
      return "--no-recursion and --auto-tune are Hyde-only (use --hyde)" if c.mode == "JEKYLL" && c.hyde_used?
      nil
    end

    # A Jekyll command whose URL is missing a bound keyword.
    private def missing_fuzz(c : ScanConfig) : String?
      return nil unless c.mode == "JEKYLL"
      if missing = missing_keyword(c)
        "Jekyll needs the #{missing} keyword in the URL (-u)"
      end
    end

    private def bad_format(c : ScanConfig) : String?
      return "export format must be json or csv" if c.output && c.format != "json" && c.format != "csv"
      nil
    end

    # The first bound keyword absent from every request part, or nil when each
    # appears somewhere (the URL, a header, the cookie, or the method). ffuf lets
    # FUZZ live in any part, so a header-only keyword is valid.
    private def missing_keyword(c : ScanConfig) : String?
      parts = [c.url, c.method, c.cookie || ""] + c.headers
      c.wordlists.each do |spec|
        keyword = Jekyll::Source.split(spec)[1]
        return keyword unless parts.any?(&.includes?(keyword))
      end
      nil
    end
  end
end
