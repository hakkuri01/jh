require "http/headers"

module JekyllHyde::Http
  # One outbound request a pool worker sends: the method, the origin-relative
  # path, the headers (operator `-H` values plus any `-b` cookie), and an
  # optional request body (`--data`). All of it is operator bytes, sent verbatim;
  # the client adds a default User-Agent only when the operator did not supply
  # one. In Jekyll each field may carry a FUZZ keyword that the template
  # substitutes per combination; in Hyde the method, headers, and body are static
  # across the walk.
  record Request, method : String, path : String, headers : HTTP::Headers, body : String? = nil do
    # Parse raw "Name: Value" lines (`-H`, and the folded `-b` cookie) into
    # HTTP::Headers, splitting on the first colon so a value may contain one. A
    # line with no colon or an empty name is skipped (the CLI validates the shape).
    def self.headers_from(raw : Enumerable(String)) : HTTP::Headers
      headers = HTTP::Headers.new
      raw.each do |line|
        next unless idx = line.index(':')
        name = line[0...idx].strip
        headers.add(name, line[(idx + 1)..].strip) unless name.empty?
      end
      headers
    end
  end
end
