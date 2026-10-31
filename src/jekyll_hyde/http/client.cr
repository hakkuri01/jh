require "http/client"
require "openssl"
require "uri"
require "../version"
require "./outcome"
require "./request"

module JekyllHyde::Http
  # One actionable line, no stack trace (AGENTS security), raised on a failed probe.
  class Error < Exception
  end

  # Whether *url* is an http(s) URL with a host: the one gate a scan target and a
  # `--filter-similar-to` reference must pass before any request fiber starts, so
  # the predicate has a single home (AGENTS Security 9).
  def self.valid_url?(url : String) : Bool
    uri = URI.parse(url)
    host = uri.host
    (uri.scheme == "http" || uri.scheme == "https") && !host.nil? && !host.empty?
  rescue
    false
  end

  # Percent-encode only the bytes that would break the request line in a
  # page-authored path segment (a Hyde wordlist word): space, C0 controls, DEL.
  # Path-structural bytes (/ ? # % .) are kept, matching feroxbuster's Url::join.
  # The one home for "is this byte safe in a request target" (AGENTS Security 2, 9).
  def self.request_token(value : String) : String
    return value unless value.each_byte.any? { |byte| unsafe_in_request?(byte) }
    String.build do |io|
      value.each_byte do |byte|
        if unsafe_in_request?(byte)
          io << '%' << byte.to_s(16, upcase: true).rjust(2, '0')
        else
          io.write_byte(byte)
        end
      end
    end
  end

  # Space, the C0 controls, and DEL: the bytes a request target cannot carry raw.
  def self.unsafe_in_request?(byte : UInt8) : Bool
    byte <= 0x20 || byte == 0x7F
  end

  # Per-request knobs. `Options.new` is the neutral default (10s, 5 MB); each mode
  # builds its own values through `.jekyll` / `.hyde`. Timeouts are in seconds.
  # *method*, *headers*, and *body* carry the operator's `-X`/`-H`/`-b`/`--data`
  # (headers as raw "Name: Value" lines, the cookie folded in); all default to a
  # plain GET with no extra headers and no body, so a scan that sets none is
  # byte-identical to before. *body*, like the headers, is operator bytes the
  # request layer sends verbatim and never records into a result.
  record Options,
    connect_timeout : Float64 = 10.0,
    read_timeout : Float64 = 10.0,
    max_body_size : Int32 = 5_242_880,
    verify_tls : Bool = true,
    user_agent : String = "jh/#{JekyllHyde::VERSION}",
    method : String = "GET",
    headers : Array(String) = [] of String,
    body : String? = nil do
    # Jekyll defaults: a 10s request timeout and a 5 MB body cap. jh caps the body
    # because an unbounded untrusted body is a DoS (AGENTS security), so a body
    # past 5 MB is truncated. *verify_tls* is the operator's `-k` choice; *method*,
    # *headers*, and *body* carry `-X`/`-H`/`-b`/`--data`.
    def self.jekyll(verify_tls : Bool = true, method : String = "GET", headers : Array(String) = [] of String, body : String? = nil) : Options
      new(connect_timeout: 10.0, read_timeout: 10.0, max_body_size: 5_242_880, verify_tls: verify_tls, method: method, headers: headers, body: body)
    end

    # Hyde defaults: a 7s request timeout and a 4 MB body read cap.
    def self.hyde(verify_tls : Bool = true, method : String = "GET", headers : Array(String) = [] of String, body : String? = nil) : Options
      new(connect_timeout: 7.0, read_timeout: 7.0, max_body_size: 4_194_304, verify_tls: verify_tls, method: method, headers: headers, body: body)
    end
  end

  # One keep-alive HTTP client bound to a single origin, the unit a pool worker
  # reuses across a scan. A redirect is recorded, not followed, so a 3xx keeps
  # its Location for the engine to queue.
  class Client
    @http : HTTP::Client
    @base_headers : HTTP::Headers

    def initialize(base : String, @options : Options = Options.new)
      @http = build(URI.parse(base))
      @base_headers = Request.headers_from(@options.headers)
    end

    # Fetch *path* with the options' static method, headers, and body (the Hyde
    # and calibration path). Raises Error on a connect, TLS, or timeout failure.
    def fetch(path : String) : Outcome
      fetch(Request.new(@options.method, path, @base_headers, @options.body))
    end

    # Fetch a fully built *request* (the Jekyll path, where method, headers, and
    # body may have had FUZZ substituted per combination). Raises Error on failure.
    def fetch(request : Request) : Outcome
      headers = merged_headers(request.headers)
      started = Time.instant
      outcome = @http.exec(request.method, request.path, headers, request.body) do |response|
        read_outcome(response, started)
      end
      # A truncated read left bytes unread on the socket; Crystal reuses a
      # keep-alive connection, and leftover body corrupts the next request on it
      # (verified), so drop the connection rather than reuse or drain it (draining
      # a hostile body past the cap is the DoS the cap exists to stop).
      @http.close if outcome.truncated
      outcome
    rescue ex : Error
      # A time-budget abort mid-body left bytes unread on the socket; drop the
      # connection so this worker's next request reconnects cleanly.
      @http.close
      raise ex
    rescue ex
      # Any other failure to get a valid response from an untrusted peer (a
      # connect, TLS, or idle-timeout error, or a malformed status line the stdlib
      # rejects with a bare Exception) becomes one clean per-request Error at this
      # single network boundary, so a direct fetch (robots.txt, a reference page)
      # cannot abort the whole scan on a hostile reply (AGENTS Security 9).
      raise Error.new("#{request.path}: #{ex.message}")
    end

    # A fresh header set for one request: the operator's headers, plus the default
    # User-Agent only when they did not supply one of their own.
    private def merged_headers(headers : HTTP::Headers) : HTTP::Headers
      result = HTTP::Headers.new
      headers.each { |name, values| values.each { |value| result.add(name, value) } }
      result["User-Agent"] = @options.user_agent unless result.has_key?("User-Agent")
      result
    end

    private def build(uri : URI) : HTTP::Client
      http = uri.scheme == "https" ? HTTP::Client.new(uri, tls: tls_context) : HTTP::Client.new(uri)
      http.connect_timeout = @options.connect_timeout.seconds
      http.read_timeout = @options.read_timeout.seconds
      # Bound the write too: a `--data` body can be large, and a target that
      # accepts the connection then stops reading would otherwise block a worker
      # mid-write with no timeout (AGENTS security, network limits).
      http.write_timeout = @options.read_timeout.seconds
      http
    end

    private def tls_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @options.verify_tls
      context
    end

    # Read at most max_body_size + 1 bytes: enough to detect overflow, never
    # enough to buffer a hostile body past the cap. One O(n) pass over a bounded
    # length (AGENTS Big O, text-from-outside). *started* is the request's start
    # instant, so the whole request is held to a time budget, not just each read.
    private def read_outcome(response : HTTP::Client::Response, started : Time::Instant) : Outcome
      # Time to first response byte: this block runs once the headers are parsed,
      # before the body read, matching ffuf's resp.Duration so a slow body does
      # not inflate the time a --mt/--ft rule sees.
      ttfb = Time.instant - started
      cap = @options.max_body_size
      budget = @options.read_timeout.seconds
      buffer = IO::Memory.new
      total = 0
      # A HEAD, 204, or 304 response has no body to stream; body_io? is nil there,
      # so guard it rather than assume every response carries a body.
      if io = response.body_io?
        chunk = Bytes.new(16_384)
        while (count = io.read(chunk)) > 0
          take = Math.min(count, cap + 1 - total)
          buffer.write(chunk[0, take])
          total += take
          break if total > cap
          # Whole-request time budget (ffuf and feroxbuster bound the entire
          # request, not just each idle read): a hostile peer that trickles bytes
          # just under the idle read timeout would otherwise hold a worker until
          # it reaches the body cap. One monotonic check per chunk.
          raise Error.new("response exceeded the time budget") if Time.instant - started > budget
        end
      end
      truncated = total > cap
      body = truncated ? buffer.to_slice[0, cap] : buffer.to_slice
      Outcome.new(
        status: response.status_code,
        body: body,
        truncated: truncated,
        location: response.headers["Location"]?,
        headers: header_blob(response.headers),
        duration: ttfb,
      )
    end

    # The response headers serialized for the regex rule, one "Name: value\r\n"
    # per value. The stdlib already bounds the header block it parses (16 KiB), so
    # HEADER_CAP is a second belt on the serialized copy, not the tight bound
    # (AGENTS Big O, text-from-outside). The bytes are NOT guaranteed valid UTF-8
    # (a header value may carry a raw 0x80..0xFF byte), so the regex rule scrubs
    # the headers and body together before matching; no scrub is needed here.
    HEADER_CAP = 65_536

    private def header_blob(headers : HTTP::Headers) : String
      String.build do |io|
        written = 0
        headers.each do |name, values|
          values.each do |value|
            line = "#{name}: #{value}\r\n"
            next if written + line.bytesize > HEADER_CAP
            io << line
            written += line.bytesize
          end
        end
      end
    end
  end
end
