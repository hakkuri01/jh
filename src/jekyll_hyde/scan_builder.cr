require "./scan_config"
require "./http/client"
require "./wordlist/list"
require "./hyde/scan"
require "./jekyll/scan"
require "./jekyll/input"
require "./jekyll/rule"
require "./jekyll/rules"
require "./jekyll/template"

module JekyllHyde
  # Turns a ScanConfig into a ready-to-run engine. The one place a scan is
  # assembled, so the TUI session, the command-line launch, and the headless
  # runner all drive the identical engine path. No TUI dependency: it only
  # constructs engine objects. Both modes expand the wordlist by any extensions
  # and stream through the same `run(cancel, pause) { }` the callers drive.
  module ScanBuilder
    extend self

    def build(config : ScanConfig) : Hyde::Scan | Jekyll::Scan
      config.mode == "JEKYLL" ? build_jekyll(config) : build_hyde(config)
    end

    # Jekyll: one source per `-w` spec (extensions only on the FUZZ source, as
    # the keyworded sources carry their own tokens), substituted into the FUZZ
    # template and kept by the matcher/filter rules.
    private def build_jekyll(config : ScanConfig) : Jekyll::Scan
      sources = config.wordlists.map do |spec|
        path, keyword = Jekyll::Source.split(spec)
        list = Wordlist::List.positional({path})
        list = list.with_extensions(config.extensions) if keyword == Jekyll::Template::KEYWORD
        Jekyll::Source.new(keyword, list)
      end
      template = Jekyll::Template.new(config.url, sources.map(&.keyword))
      input = Jekyll::Input.new(sources, config.input_mode)
      options = Http::Options.jekyll(verify_tls: !config.insecure?, method: config.method, headers: config.request_headers, body: config.body)
      Jekyll::Scan.new(template, input, options, concurrency: config.threads, rules: jekyll_rules(config), auto_calibrate: config.calibrate?)
    end

    # Hyde: recurse from the origin with one deduplicated wordlist; --no-recursion
    # caps the walk at the target itself, and --filter-similar-to seeds the
    # near-duplicate filters from operator reference pages.
    private def build_hyde(config : ScanConfig) : Hyde::Scan
      paths = config.wordlists.map { |spec| Jekyll::Source.split(spec)[0] }
      list = Wordlist::List.deduplicated(paths).with_extensions(config.extensions)
      depth = config.no_recursion? ? 1 : config.depth
      options = Http::Options.hyde(verify_tls: !config.insecure?, method: config.method, headers: config.request_headers, body: config.body)
      Hyde::Scan.new(config.url, list, options, concurrency: config.threads, max_depth: depth, auto_tune: config.auto_tune?, similar_to: config.filter_similar)
    end

    # The rules from the parsed matchers and filters; with no matcher given, the
    # default status matcher stands in so a bare scan still keeps real hits.
    private def jekyll_rules(config : ScanConfig) : Jekyll::Rules
      matchers = config.matchers.empty? ? [Jekyll::Rule.build("status", Jekyll::Rules::DEFAULT_STATUS)] : config.matchers
      Jekyll::Rules.new(matchers, config.filters, matcher_mode: config.matcher_mode, filter_mode: config.filter_mode)
    end
  end
end
