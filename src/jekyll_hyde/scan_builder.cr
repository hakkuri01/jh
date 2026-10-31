require "base64"
require "uri"
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
      # The one home for target validation on the build path: both the TUI session
      # and the headless runner reach the engine through here, so neither keeps
      # its own copy of the check (AGENTS Security 9).
      raise ArgumentError.new("not a valid URL; use http://host or https://host") unless Http.valid_url?(config.url)
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
      options = Http::Options.jekyll(verify_tls: !config.insecure?, method: config.method, headers: request_headers(config), body: config.body)
      Jekyll::Scan.new(template, input, options, concurrency: config.threads, rules: jekyll_rules(config), auto_calibrate: config.calibrate?)
    end

    # Hyde: recurse from the origin with one deduplicated wordlist; --no-recursion
    # caps the walk at the target itself, and --filter-similar-to seeds the
    # near-duplicate filters from operator reference pages.
    private def build_hyde(config : ScanConfig) : Hyde::Scan
      paths = config.wordlists.map { |spec| Jekyll::Source.split(spec)[0] }
      list = Wordlist::List.deduplicated(paths).with_extensions(config.extensions)
      depth = config.no_recursion? ? 1 : config.depth
      options = Http::Options.hyde(verify_tls: !config.insecure?, method: config.method, headers: request_headers(config), body: config.body)
      Hyde::Scan.new(config.url, list, options, concurrency: config.threads, max_depth: depth, auto_tune: config.auto_tune?, similar_to: config.filter_similar)
    end

    # The rules from the parsed matchers and filters; with no matcher given, the
    # default status matcher stands in so a bare scan still keeps real hits.
    private def jekyll_rules(config : ScanConfig) : Jekyll::Rules
      matchers = config.matchers.empty? ? [Jekyll::Rule.build("status", Jekyll::Rules::DEFAULT_STATUS)] : config.matchers
      Jekyll::Rules.new(matchers, config.filters, matcher_mode: config.matcher_mode, filter_mode: config.filter_mode)
    end

    # The request headers plus HTTP Basic auth from any userinfo in the target URL
    # (http://user:pass@host): userinfo is the URL syntax for credentials, so an
    # operator who types it means to authenticate. An Authorization header they
    # set themselves wins. The userinfo never reaches a result URL (built from the
    # host-only origin), so the supplied secret is not exported.
    private def request_headers(config : ScanConfig) : Array(String)
      headers = config.request_headers
      auth = basic_auth(config.url)
      return headers unless auth
      return headers if headers.any? { |line| line.lstrip.downcase.starts_with?("authorization:") }
      headers + [auth]
    end

    private def basic_auth(url : String) : String?
      uri = URI.parse(url) rescue return nil
      user = uri.user
      return nil unless user
      "Authorization: Basic #{Base64.strict_encode("#{user}:#{uri.password}")}"
    end
  end
end
