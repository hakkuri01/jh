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
    URL_CHARS = /["<>\\^`{|} ]/

    # The LinkFinder regex (GerbenJavado/LinkFinder): quoted URL and endpoint-like
    # strings, extended mode, group 1 without the quotes. The single-quoted
    # heredoc keeps the backslashes literal, which is why ameba's unescape rule is
    # off on the line.
    LINKFINDER = Regex.new(<<-'PATTERN', Regex::Options::EXTENDED) # ameba:disable Style/HeredocEscape
      (?:"|')
      (
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
      (?:"|')
      PATTERN

    @host : String

    def initialize(@origin : String)
      @host = URI.parse(@origin).host || ""
    end

    # The in-scope paths *body* references (resolved against *from*, the path it
    # was served at), each expanded to its parent sub-paths. Paths are origin
    # relative; a directory keeps its trailing slash, the deepest leaf does not.
    def extract(body : String, from : String) : Set(String)
      links = Set(String).new
      body.scan(ATTRIBUTE) { |match| add(match[1], from, links) }
      body.scan(LINKFINDER) { |match| add(match[1], from, links) }
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
      return if link.empty?
      path = scoped_path(link, from)
      return unless path
      sub_paths(path).each { |sub| links << "/#{sub}" }
    end

    # The origin-relative path of *link*, or nil when it points off-origin.
    private def scoped_path(link : String, from : String) : String?
      candidate = link.starts_with?("//") ? "http:#{link}" : link
      if candidate =~ %r{\Ahttps?://}i
        uri = URI.parse(candidate) rescue return nil
        uri.host == @host ? uri.path : nil
      elsif link.starts_with?("/")
        link
      else
        resolve(link, from)
      end
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
    # no trailing slash; each parent directory gets one.
    private def sub_paths(path : String) : Array(String)
      parts = normalize(path).split('/').map(&.gsub(URL_CHARS, "")).reject(&.empty?)
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
