require "http/client"
require "openssl"
require "uri"
require "../version"
require "./outcome"

module JekyllHyde::Http
  # One actionable line, no stack trace (AGENTS security), raised on a failed probe.
  class Error < Exception
  end

  # Per-request knobs. `Options.new` is the neutral default (10s, 5 MB); each mode
  # builds its own values through `.jekyll` / `.hyde`. Timeouts are in seconds.
  record Options,
    connect_timeout : Float64 = 10.0,
    read_timeout : Float64 = 10.0,
    max_body_size : Int32 = 5_242_880,
    verify_tls : Bool = true,
    user_agent : String = "jh/#{JekyllHyde::VERSION}" do
    # Jekyll defaults: a 10s request timeout and a 5 MB body cap. jh caps the body
    # because an unbounded untrusted body is a DoS (AGENTS security), so a body
    # past 5 MB is truncated.
    def self.jekyll : Options
      new(connect_timeout: 10.0, read_timeout: 10.0, max_body_size: 5_242_880)
    end

    # Hyde defaults: a 7s request timeout and a 4 MB body read cap.
    def self.hyde : Options
      new(connect_timeout: 7.0, read_timeout: 7.0, max_body_size: 4_194_304)
    end
  end

  # One keep-alive HTTP client bound to a single origin, the unit a pool worker
  # reuses across a scan. GET only for now; a redirect is recorded, not followed,
  # so a 3xx keeps its Location for the engine to queue.
  class Client
    @http : HTTP::Client

    def initialize(base : String, @options : Options = Options.new)
      @http = build(URI.parse(base))
    end

    # Fetch *path* once and return its Outcome. Raises Error on a connect, TLS, or
    # timeout failure.
    def fetch(path : String) : Outcome
      headers = HTTP::Headers{"User-Agent" => @options.user_agent}
      started = Time.instant
      outcome = @http.get(path, headers) { |response| read_outcome(response) }
      elapsed = Time.instant - started
      # A truncated read left bytes unread on the socket; Crystal reuses a
      # keep-alive connection, and leftover body corrupts the next request on it
      # (verified), so drop the connection rather than reuse or drain it (draining
      # a hostile body past the cap is the DoS the cap exists to stop).
      @http.close if outcome.truncated
      outcome.copy_with(duration: elapsed)
    rescue ex : IO::Error | OpenSSL::SSL::Error
      raise Error.new("#{path}: #{ex.message}")
    end

    private def build(uri : URI) : HTTP::Client
      http = uri.scheme == "https" ? HTTP::Client.new(uri, tls: tls_context) : HTTP::Client.new(uri)
      http.connect_timeout = @options.connect_timeout.seconds
      http.read_timeout = @options.read_timeout.seconds
      http
    end

    private def tls_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @options.verify_tls
      context
    end

    # Read at most max_body_size + 1 bytes: enough to detect overflow, never
    # enough to buffer a hostile body past the cap. One O(n) pass over a bounded
    # length (AGENTS Big O, text-from-outside).
    private def read_outcome(response : HTTP::Client::Response) : Outcome
      cap = @options.max_body_size
      buffer = IO::Memory.new
      chunk = Bytes.new(16_384)
      total = 0
      io = response.body_io
      while (count = io.read(chunk)) > 0
        take = Math.min(count, cap + 1 - total)
        buffer.write(chunk[0, take])
        total += take
        break if total > cap
      end
      truncated = total > cap
      body = truncated ? buffer.to_slice[0, cap] : buffer.to_slice
      Outcome.new(
        status: response.status_code,
        body: body,
        truncated: truncated,
        location: response.headers["Location"]?,
        content_type: response.content_type,
        headers: header_blob(response.headers),
      )
    end

    # The response headers serialized for the regex rule, one "Name: value\r\n"
    # per value, bounded by HEADER_CAP so a hostile server cannot make this
    # unbounded (AGENTS Big O, text-from-outside). Crystal has already decoded
    # them to valid UTF-8, so no scrub is needed here.
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
