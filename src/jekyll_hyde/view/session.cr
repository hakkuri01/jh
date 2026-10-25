require "../tui/model"
require "../tui/message"
require "../core/response"
require "../core/results"
require "../http/client"
require "../wordlist/list"
require "../hyde/scan"
require "../jekyll/scan"
require "../jekyll/input"
require "../jekyll/rule"
require "../jekyll/rules"
require "../jekyll/template"
require "../scan_config"
require "uri"

# The bridge between a running scan engine and the Elm loop.
module JekyllHyde::View
  # A kept result streamed up from a running scan; carries its session so a
  # stale result from a cancelled run can be told from the live one.
  struct ScanHitMsg < Tui::Msg
    getter session : ScanSession
    getter response : Core::Response

    def initialize(@session : ScanSession, @response : Core::Response)
    end
  end

  # A frame came due with no new hit: the scanning view redraws so the activity
  # pulse and the elapsed-time messages advance even when nothing is found.
  struct ScanTickMsg < Tui::Msg
    getter session : ScanSession

    def initialize(@session : ScanSession)
    end
  end

  # A scan that ran to its end.
  struct ScanDoneMsg < Tui::Msg
    getter session : ScanSession

    def initialize(@session : ScanSession)
    end
  end

  # A scan that failed to load its wordlist or reach its target; *reason* is one
  # actionable line, no stack trace (AGENTS security).
  struct ScanFailedMsg < Tui::Msg
    getter session : ScanSession
    getter reason : String

    def initialize(@session : ScanSession, @reason : String)
    end
  end

  # One running scan wired into the Elm loop, built from a ScanConfig so a
  # form-composed scan and a command-line scan drive the very same engine path.
  # The scan runs on its own fiber and streams each kept result through a
  # channel; the loop pulls with `listen`, a select over that channel and a frame
  # timeout, so one command both streams hits at the UI's pace (backpressure
  # throttles the scan, not the UI) and keeps a steady clock for the activity
  # pulse. The session keeps the hits seen and exposes live request and error
  # counts read off the engine. q cancels: the engine stops within one pool of
  # in-flight requests, the fiber ends, and the timeout keeps any waiting
  # `listen` from blocking on a silent channel.
  class ScanSession
    getter hits : Array(Core::Response)
    getter? running : Bool
    getter error : String?
    getter target : String

    @channel : Channel(Tui::Msg)
    @cancelled : Bool
    @paused : Bool
    @config : ScanConfig
    @scan : (Hyde::Scan | Jekyll::Scan)? = nil
    @export_warning : String? = nil

    def initialize(@config : ScanConfig)
      @target = @config.url
      @hits = [] of Core::Response
      @running = true
      @error = nil
      @cancelled = false
      @paused = false
      @channel = Channel(Tui::Msg).new(128)
      spawn perform
    end

    # The command the loop runs to pull the next scan event: the next hit, or a
    # tick when *frame* elapses first, so the pulse keeps moving between hits.
    def listen(frame : Time::Span) : Tui::Cmd
      channel, session = @channel, self
      Tui::Cmd.new do
        select
        when msg = channel.receive
          msg
        when timeout(frame)
          ScanTickMsg.new(session).as(Tui::Msg)
        end
      end
    end

    # Requests completed and errored so far, read live off the engine.
    def requests : Int32
      @scan.try(&.completed) || 0
    end

    def errors : Int32
      @scan.try(&.errors) || 0
    end

    # A non-fatal notice for the dashboard footer: a failed export, or the
    # engine's crawl-cap warning. Read on the UI fiber at a yield point.
    def warning : String?
      return @export_warning if @export_warning
      scan = @scan
      scan.is_a?(Hyde::Scan) ? scan.warning : nil
    end

    def record(response : Core::Response) : Nil
      @hits << response
    end

    def finish : Nil
      @running = false
    end

    def fail(reason : String) : Nil
      @running = false
      @error = reason
    end

    # Stop the scan. The engine sees the flag within one pool of in-flight
    # requests. Safe under the single-thread scheduler, where the flag is set on
    # the UI fiber and read on the scan fiber only at yield points.
    def cancel : Nil
      @cancelled = true
    end

    # Hold or resume the scan: while paused the engine's feed stops sending new
    # requests (in-flight ones finish), so p is a safe "stop hammering the target
    # for a moment". Only meaningful while running.
    def toggle_pause : Nil
      @paused = !@paused if @running
    end

    def paused? : Bool
      @paused
    end

    private def perform : Nil
      validate_target!
      scan = build_scan
      @scan = scan
      results = scan.run(cancel: -> { @cancelled }, pause: -> { @paused }) do |response|
        @channel.send(ScanHitMsg.new(self, response)) unless @cancelled
      end
      unless @cancelled
        @export_warning = export(results)
        @channel.send(ScanDoneMsg.new(self))
      end
    rescue ex : File::Error
      # A wordlist that cannot be read: one clean line, no absolute path
      # (AGENTS Security 7). The export path's own failures are handled in export.
      @channel.send(ScanFailedMsg.new(self, "could not read wordlist: #{Path[ex.file].basename}")) unless @cancelled
    rescue ex
      @channel.send(ScanFailedMsg.new(self, ex.message || "scan failed")) unless @cancelled
    end

    # Builds the engine for the mode. Both modes expand the wordlist by any
    # extensions and stream through the same `run(cancel, pause) { }` the loop
    # drives. This is the one place a scan is assembled, for the form and the
    # command line alike.
    private def build_scan : Hyde::Scan | Jekyll::Scan
      @config.mode == "JEKYLL" ? build_jekyll : build_hyde
    end

    # Jekyll: one source per `-w` spec (extensions only on the FUZZ source, as
    # the keyworded sources carry their own tokens), substituted into the FUZZ
    # template and kept by the matcher/filter rules.
    private def build_jekyll : Jekyll::Scan
      sources = @config.wordlists.map do |spec|
        path, keyword = Jekyll::Source.split(spec)
        list = Wordlist::List.positional({path})
        list = list.with_extensions(@config.extensions) if keyword == Jekyll::Template::KEYWORD
        Jekyll::Source.new(keyword, list)
      end
      template = Jekyll::Template.new(@config.url, sources.map(&.keyword))
      input = Jekyll::Input.new(sources, @config.input_mode)
      options = Http::Options.jekyll(verify_tls: !@config.insecure?, method: @config.method, headers: @config.request_headers, body: @config.body)
      Jekyll::Scan.new(template, input, options, concurrency: @config.threads, rules: jekyll_rules, auto_calibrate: @config.calibrate?)
    end

    # Hyde: recurse from the origin with one deduplicated wordlist; --no-recursion
    # caps the walk at the target itself.
    private def build_hyde : Hyde::Scan
      paths = @config.wordlists.map { |spec| Jekyll::Source.split(spec)[0] }
      list = Wordlist::List.deduplicated(paths).with_extensions(@config.extensions)
      depth = @config.no_recursion? ? 1 : @config.depth
      options = Http::Options.hyde(verify_tls: !@config.insecure?, method: @config.method, headers: @config.request_headers, body: @config.body)
      Hyde::Scan.new(@config.url, list, options, concurrency: @config.threads, max_depth: depth, auto_tune: @config.auto_tune?)
    end

    # The rules from the parsed matchers and filters; with no matcher given, the
    # default status matcher stands in so a bare scan still keeps real hits.
    private def jekyll_rules : Jekyll::Rules
      matchers = @config.matchers.empty? ? [Jekyll::Rule.build("status", Jekyll::Rules::DEFAULT_STATUS)] : @config.matchers
      Jekyll::Rules.new(matchers, @config.filters, matcher_mode: @config.matcher_mode, filter_mode: @config.filter_mode)
    end

    # Write the results to the -o path when one is set and the scan finished on
    # its own, returning a one-line notice if the write fails (the hits are
    # already on the dashboard, so a bad path is surfaced, not fatal).
    private def export(results : Core::Results) : String?
      path = @config.output
      return nil unless path
      data = @config.format == "csv" ? results.to_csv : results.to_json
      begin
        write_atomic(path, data)
        nil
      rescue File::Error
        # No absolute path in the message (AGENTS Security 7); on-screen results stay.
        "could not write results to #{Path[path].basename}"
      end
    end

    # Write to a sibling temp file and rename over the target, so a failed or
    # interrupted write never replaces a good export with a partial one.
    private def write_atomic(path : String, data : String) : Nil
      tmp = "#{path}.#{Process.pid}.part"
      begin
        File.write(tmp, data)
        File.rename(tmp, path)
      rescue ex
        File.delete?(tmp)
        raise ex
      end
    end

    # Validate the operator-supplied target before any request fiber starts, so a
    # malformed URL fails as one clean line here (caught below) instead of each
    # pool worker raising an unhandled exception that corrupts the TUI.
    private def validate_target! : Nil
      uri = URI.parse(@target)
      host = uri.host
      return if (uri.scheme == "http" || uri.scheme == "https") && host && !host.empty?
      raise ArgumentError.new("not a valid URL; use http://host or https://host")
    end
  end
end
