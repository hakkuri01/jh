require "uri"

module JekyllHyde::Jekyll
  # A FUZZ template: a URL carrying one or more keywords in its path or query.
  # The origin (scheme, host, port) is fixed, and each keyword is substituted
  # with its wordlist entry, verbatim (operator bytes; percent-encoding is an
  # opt-in flag to come). Keywords stay out of the host, so one scan targets one
  # origin, which is what the request pool binds to. A keyword need not appear in
  # the URL: it may be fuzzed in a header, cookie, or method instead (ffuf lets
  # FUZZ live in any request part), so the template substitutes whichever
  # keywords are present and leaves the rest; the command line checks that each
  # keyword appears in *some* part.
  class Template
    KEYWORD = "FUZZ"

    getter origin : String
    getter keywords : Array(String)
    @template : String
    @pattern : Regex

    def initialize(raw : String, @keywords : Array(String) = [KEYWORD])
      raise ArgumentError.new("a template needs at least one keyword") if @keywords.empty?
      raise ArgumentError.new("every keyword must be non-empty") if @keywords.any?(&.empty?)
      uri = URI.parse(raw)
      scheme, host = uri.scheme, uri.host
      unless scheme == "http" || scheme == "https"
        raise ArgumentError.new("not a valid URL; use http://host/FUZZ")
      end
      raise ArgumentError.new("not a valid URL; use http://host/FUZZ") if host.nil? || host.empty?
      @keywords.each do |keyword|
        raise ArgumentError.new("#{keyword} cannot be in the host") if host.includes?(keyword)
      end
      @origin = (port = uri.port) ? "#{scheme}://#{host}:#{port}" : "#{scheme}://#{host}"
      path = uri.path.empty? ? "/" : uri.path
      @template = (query = uri.query) ? "#{path}?#{query}" : path
      # One alternation, longest keyword first so a keyword that prefixes another
      # cannot clip it; gsub then substitutes every keyword in a single pass over
      # the original, so a value that happens to contain a keyword is never
      # re-substituted (a naive sequential replace can, this does not).
      @pattern = Regex.union(@keywords.sort_by { |keyword| -keyword.size })
    end

    # The request path for *values*: every keyword in the URL replaced by its
    # entry. Keywords not in the URL (fuzzed elsewhere) leave it unchanged.
    def path(values : Hash(String, String)) : String
      fill(@template, values)
    end

    # Single-keyword convenience: fills the template's sole keyword with *word*.
    def path(word : String) : String
      path({@keywords.first => word})
    end

    # Substitute *values* into any request text (the URL, a header line, the
    # method) in one pass with the shared keyword pattern, so a header and the URL
    # are fuzzed the same way. Text with no keyword is returned unchanged.
    def fill(text : String, values : Hash(String, String)) : String
      text.gsub(@pattern) { |match| values[match] }
    end
  end
end
