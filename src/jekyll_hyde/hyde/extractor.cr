require "uri"

module JekyllHyde::Hyde
  # Link extraction, adapted to the stdlib (no DOM parser, no URL crate): links
  # come from an href/src/action attribute regex and a robots.txt regex, and
  # relative URLs are resolved here. The LinkFinder regex adds endpoints embedded
  # in JavaScript. Sub-path expansion and same-origin scope are applied to every
  # discovered link.
  class Extractor
    # Values of the link-bearing HTML attributes (href, src, action).
    ATTRIBUTE = /\b(?:href|src|action)\s*=\s*["']([^"']*)["']/i
    # robots.txt Allow/Disallow lines (handled per line, so no multiline flag).
    ROBOTS = /^\s*(?:allow|disallow)\s*:\s*([^\s#]*)/i
    # RFC 3986 characters that may not appear in a path, stripped per segment.
    # This mirrors feroxbuster's url_regex.replace_all exactly: a deliberate
    # parity choice. AGENTS Security 2 would prefer percent-encoding to repair,
    # but these bytes are illegal in a path anyway and both references strip them,
    # so stripping is the intentional standard here, revisited only if a real
    # target is ever shown to be mis-probed because of it.
    URL_CHARS = /["<>\\^`{|} ]/
    # The deepest path expanded into parent sub-paths. The walk is O(segments^2)
    # in time and output, so a hostile body emitting a link with thousands of
    # segments is capped here: beyond this, only the full path is kept, no parents
    # (AGENTS Big O 6, text-from-outside). Real paths are nowhere near this.
    MAX_PATH_SEGMENTS = 100
    # The most links one response body yields. A hostile page can pack a
    # body-cap-sized body with unique links; without a cap here, extract would
    # expand every one into sub-paths and build a multi-million-entry set before
    # the scan applied any limit, so the cap bounds the work, not just the queue
    # (AGENTS Big O 6). 500 is feroxbuster's effective per-response breadth.
    MAX_LINKS = 500
    # The longest a single page-authored link may be. A body-cap-sized single
    # segment slips past MAX_PATH_SEGMENTS (it has one segment), so its byte length
    # is capped before it ever reaches the request line, the result set, or a
    # per-frame sanitize on the dashboard (AGENTS Big O 6, line-length cap).
    MAX_LINK_BYTES = 8_192

    # The LinkFinder regex (GerbenJavado/LinkFinder): quoted URL and endpoint-like
    # strings, extended mode, group 1 without the quotes. The single-quoted
    # heredoc keeps the backslashes literal, which is why ameba's unescape rule is
    # off on the line.
    #
    # The alternation is wrapped in an atomic group `(?>...)`. feroxbuster runs
    # this on Rust's linear regex engine; PCRE2 (Crystal's engine) backtracks, and
    # a quoted run with no closing quote (`"/a/a/a...`) makes it retry the greedy
    # run O(n) times for O(n squared) blow-up, a hostile-target DoS within the body
    # cap. Every branch's run already stops before the closing quote, so it never
    # needs to give characters back on real input: the atomic group changes no
    # match, it only forbids the backtracking feroxbuster's engine never did.
    LINKFINDER = Regex.new(<<-'PATTERN', Regex::Options::EXTENDED) # ameba:disable Style/HeredocEscape
      (?:"|')
      (
        (?>
          ((?:[a-zA-Z]{1,10}://|//)[^"'/]{1,}\.[a-zA-Z]{2,}[^"']{0,})
          |
          ((?:/|\.\./|\./)[^"'><,;| *()(%%$^/\\\[\]][^"'><,;|()]{1,})
          |
          ([a-zA-Z0-9_\-/]{1,}/[a-zA-Z0-9_\-/.]{1,}\.(?:[a-zA-Z]{1,4}|action)(?:[\?|\#][^"|']{0,}|))
          |
          ([a-zA-Z0-9_\-/]{1,}/[a-zA-Z0-9_\-/]{3,}(?:[\?|\#][^"|']{0,}|))
          |
          ([a-zA-Z0-9_\-]{1,}\.(?:php|asp|aspx|jsp|json|action|html|js|txt|xml)(?:[\?|\#][^"|']{0,}|))
        )
      )
      (?:"|')
      PATTERN

    @host : String

    def initialize(@origin : String)
      @host = URI.parse(@origin).host || ""
    end

    # The in-scope paths *body* references (resolved against *from*), each expanded
    # to its parent sub-paths. Scanning stops at MAX_LINKS, so one hostile body
    # cannot drive an unbounded set before the scan sees it.
    def extract(body : String, from : String) : Set(String)
      links = Set(String).new
      body.scan(ATTRIBUTE) { |match| break if links.size >= MAX_LINKS; add(match[1], from, links) }
      body.scan(LINKFINDER) { |match| break if links.size >= MAX_LINKS; add(match[1], from, links) }
      links
    end

    # The in-scope paths an Allow/Disallow lists in a robots.txt *body*.
    def extract_robots(body : String) : Set(String)
      links = Set(String).new
      body.each_line do |line|
        next unless match = line.match(ROBOTS)
        add(match[1], "/", links)
      end
      links
    end

    private def add(link : String, from : String, links : Set(String)) : Nil
      return if link.empty? || link.bytesize > MAX_LINK_BYTES
      path = scoped_path(link, from)
      return unless path
      sub_paths(path).each { |sub| links << "/#{sub}" }
    end

    # The origin-relative path of *link*, or nil when it points off-origin.
    private def scoped_path(link : String, from : String) : String?
      candidate = link.starts_with?("//") ? "http:#{link}" : link
      if candidate =~ %r{\Ahttps?://}i
        uri = URI.parse(candidate) rescue return nil
        same_host?(uri.host) ? uri.path : nil
      elsif link =~ /\A[a-zA-Z][a-zA-Z0-9+.\-]*:/
        # A non-http(s) scheme (mailto:, tel:, javascript:, data:): not a path to
        # request. feroxbuster drops these off-origin through Url::join;
        # concatenating them would put junk, or a huge data: URI, on the wire.
        nil
      elsif link.starts_with?("/")
        link
      else
        resolve(link, from)
      end
    end

    # A host matches the scan origin case-insensitively: RFC 3986 host is case-
    # insensitive, so a link whose host differs only in case is same-origin, not
    # off-scope.
    private def same_host?(host : String?) : Bool
      return false unless host
      host.compare(@host, case_insensitive: true) == 0
    end

    private def resolve(link : String, from : String) : String
      slash = from.rindex('/')
      base = slash ? from[0, slash + 1] : "/"
      collapse(base + link)
    end

    # RFC 3986 remove_dot_segments, enough to fold ./ and ../ out of a path.
    private def collapse(path : String) : String
      segments = [] of String
      path.split('/').each do |segment|
        case segment
        when "", "." then next
        when ".."    then segments.pop?
        else              segments << segment
        end
      end
      segments.join("/")
    end

    # Sub-path expansion: "a/b/c.js" -> ["a/b/c.js", "a/b/", "a/"]. The leaf keeps
    # no slash, each parent gets one. A pathologically deep path is not expanded
    # into every parent (quadratic); past the cap only the full path is kept.
    private def sub_paths(path : String) : Array(String)
      parts = normalize(path).split('/').map(&.gsub(URL_CHARS, "")).reject(&.empty?)
      return [] of String if parts.empty?
      return [parts.join("/")] if parts.size > MAX_PATH_SEGMENTS
      result = [] of String
      parts.size.times do |index|
        break if parts.empty?
        joined = parts.join("/")
        result << (index > 0 ? "#{joined}/" : joined) unless joined.empty?
        parts.pop
      end
      result
    end

    # Trim whitespace, drop a leading slash, remove any query or fragment.
    private def normalize(path : String) : String
      cleaned = path.strip.lstrip('/').gsub(/\s/, "")
      cleaned = cleaned.split('?', 2).first
      cleaned.split('#', 2).first
    end
  end
end
