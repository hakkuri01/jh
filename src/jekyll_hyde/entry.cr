require "option_parser"
require "./version"
require "./render/logo"
require "./render/sanitize"
require "./core/results"
require "./wordlist/list"
require "./http/client"
require "./hyde/scan"
require "./jekyll/scan"
require "./jekyll/template"
require "./jekyll/rules"

module JekyllHyde
  # The one-shot CLI: parse argv, print the static banner, run a single scan with
  # each kept result streamed inline, then a summary, with optional export. No
  # opener, no mode switch, no full-screen TUI; the complement to the interactive
  # shell. `run` returns the process exit code.
  class Entry
    # The parsed invocation. match/filter are Jekyll status rules; output/format
    # drive export.
    record Config,
      mode : String,
      url : String,
      wordlist : String,
      threads : Int32,
      depth : Int32,
      match : String?,
      filter : String?,
      calibrate : Bool,
      output : String?,
      format : String,
      help : Bool

    def self.run(argv : Array(String), io : IO = STDOUT) : Int32
      new(io).run(argv)
    end

    def initialize(@io : IO)
    end

    def run(argv : Array(String)) : Int32
      parser, config = parse(argv)
      if config.help
        @io.puts parser
        return 0
      end
      if problem = validate(config)
        @io.puts "error: #{problem}"
        return 2
      end
      banner
      report = perform(config)
      summary(report)
      export(report, config)
      0
    rescue ex : IO::Error | ArgumentError | Http::Error
      @io.puts "error: #{ex.message}"
      2
    end

    private def parse(argv : Array(String)) : {OptionParser, Config}
      mode, url, wordlist, threads, depth = "HYDE", "", "", 40, 4
      match, filter, output = nil.as(String?), nil.as(String?), nil.as(String?)
      calibrate, help, format = false, false, "json"
      parser = OptionParser.new do |p|
        p.banner = "usage: jh [--hyde|--jekyll] -u URL -w WORDLIST [options]"
        p.on("--hyde", "recursive discovery (default)") { mode = "HYDE" }
        p.on("--jekyll", "templated FUZZ fuzzing") { mode = "JEKYLL" }
        p.on("-u URL", "--url=URL", "target URL (FUZZ marks the Jekyll injection point)") { |v| url = v }
        p.on("-w FILE", "--wordlist=FILE", "wordlist path") { |v| wordlist = v }
        p.on("-t N", "--threads=N", "concurrent requests (default 40)") { |v| threads = v.to_i? || threads }
        p.on("-d N", "--depth=N", "max recursion depth, Hyde (default 4)") { |v| depth = v.to_i? || depth }
        p.on("--match=CODES", "match status codes, Jekyll (e.g. 200,301,403)") { |v| match = v }
        p.on("--filter=CODES", "filter status codes, Jekyll") { |v| filter = v }
        p.on("--calibrate", "autocalibrate wildcard filters, Jekyll") { calibrate = true }
        p.on("-o FILE", "--output=FILE", "write results to FILE") { |v| output = v }
        p.on("--format=FMT", "export format: json or csv (default json)") { |v| format = v }
        p.on("-h", "--help", "show this help") { help = true }
        p.invalid_option { |flag| raise ArgumentError.new("unknown option #{flag}") }
      end
      parser.parse(argv)
      {parser, Config.new(mode, url, wordlist, threads, depth, match, filter, calibrate, output, format, help)}
    end

    private def validate(config : Config) : String?
      return "a target URL is required (-u)" if config.url.empty?
      return "a wordlist is required (-w)" if config.wordlist.empty?
      return "Jekyll needs a FUZZ keyword in the URL (-u)" if config.mode == "JEKYLL" && !config.url.includes?("FUZZ")
      return "export format must be json or csv" if config.output && config.format != "json" && config.format != "csv"
      nil
    end

    # One scan in the chosen mode, each kept result streamed inline as it lands.
    private def perform(config : Config) : Report
      if config.mode == "JEKYLL"
        list = Wordlist::List.positional({config.wordlist})
        scan = Jekyll::Scan.new(Jekyll::Template.new(config.url), list, concurrency: config.threads, rules: rules(config), auto_calibrate: config.calibrate)
        Report.new(scan.run { |response| row(response) }, scan.completed, scan.errors)
      else
        list = Wordlist::List.deduplicated({config.wordlist})
        scan = Hyde::Scan.new(config.url, list, concurrency: config.threads, max_depth: config.depth)
        Report.new(scan.run { |response| row(response) }, scan.completed, scan.errors)
      end
    end

    private def rules(config : Config) : Jekyll::Rules
      matchers = [Jekyll::Rule.build("status", config.match || Jekyll::Rules::DEFAULT_STATUS)]
      filters = (value = config.filter) ? [Jekyll::Rule.build("status", value)] : [] of Jekyll::Rule
      Jekyll::Rules.new(matchers, filters)
    end

    # One result line; the url is server-derivable (Hyde mines links), so it is
    # sanitized before it reaches the terminal (AGENTS: untrusted output).
    private def row(response : Core::Response) : Nil
      @io.puts "  %-3d  %9d  %6dw  %6dl  %s" % [response.status, response.size, response.words, response.lines, Render.sanitize(response.url)]
    end

    private def summary(report : Report) : Nil
      @io.puts ""
      @io.puts "#{report.results.entries.size} results · #{report.requests} requests · #{report.errors} errors"
    end

    private def export(report : Report, config : Config) : Nil
      path = config.output
      return unless path
      File.write(path, config.format == "csv" ? report.results.to_csv : report.results.to_json)
      @io.puts "wrote #{report.results.entries.size} results to #{path} (#{config.format})"
    end

    private def banner : Nil
      @io.puts Render::Logo.banner(false)
    end

    # The finished scan: its results and the request/error tallies for the summary.
    private record Report, results : Core::Results, requests : Int32, errors : Int32
  end
end
