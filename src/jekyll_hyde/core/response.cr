require "./metrics"

# One kept scan result: the probed URL and its measured status, size in bytes,
# words, and lines, plus a redirect Location when present. Counts come from
# Core::Metrics the active engine's way; server text is sanitized at render.
module JekyllHyde::Core
  record Response,
    url : String,
    status : Int32,
    size : Int64,
    words : Int32,
    lines : Int32,
    location : String? = nil

  struct Response
    # Jekyll: size and counts from the raw body (the byte-counting scheme).
    def self.jekyll(url : String, status : Int32, body : Bytes, location : String?) : Response
      new(url, status, body.size.to_i64, Metrics.jekyll_words(body), Metrics.jekyll_lines(body), location)
    end

    # Hyde: size from the raw body, counts from the decoded *text* (scrubbed to
    # valid UTF-8). The caller decodes once and reuses that text for the counts,
    # the similarity filter, and link mining, so a kept body is scrubbed once.
    def self.hyde(url : String, status : Int32, body : Bytes, location : String?, *, text : String) : Response
      new(url, status, body.size.to_i64, Metrics.hyde_words(text), Metrics.hyde_lines(text), location)
    end
  end
end
