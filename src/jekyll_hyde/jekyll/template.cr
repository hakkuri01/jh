require "uri"

module JekyllHyde::Jekyll
  # A FUZZ template: a URL carrying one or more keywords in its path or query.
  # The origin (scheme, host, port) is fixed, and each keyword is substituted
  # with its wordlist entry, verbatim (operator bytes; percent-encoding is an
  # opt-in flag to come). Keywords stay out of the host, so one scan targets one
  # origin, which is what the request pool binds to.
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
      @keywords.each do |keyword|
        raise ArgumentError.new("the URL must contain the #{keyword} keyword") unless @template.includes?(keyword)
      end
      # One alternation, longest keyword first so a keyword that prefixes another
      # cannot clip it; gsub then substitutes every keyword in a single pass over
      # the original, so a value that happens to contain a keyword is never
      # re-substituted (a naive sequential replace can, this does not).
      @pattern = Regex.union(@keywords.sort_by { |keyword| -keyword.size })
    end

    # The request path for *values*: every keyword replaced by its entry.
    def path(values : Hash(String, String)) : String
      @template.gsub(@pattern) { |match| values[match] }
    end

    # Single-keyword convenience: fills the template's sole keyword with *word*.
    def path(word : String) : String
      path({@keywords.first => word})
    end
  end
end
