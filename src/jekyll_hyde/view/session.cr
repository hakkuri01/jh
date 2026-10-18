require "../tui/model"
require "../tui/message"
require "../core/response"
require "../wordlist/list"
require "../hyde/scan"
require "../jekyll/scan"
require "../jekyll/template"
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

  # One running scan wired into the Elm loop, Hyde or Jekyll by *mode*. The scan
  # runs on its own fiber and streams each kept result through a channel; the loop
  # pulls with `listen`, a select over that channel and a frame timeout, so one
  # command both streams hits at the UI's pace (backpressure throttles the scan,
  # not the UI) and keeps a steady clock for the activity pulse. The session keeps
  # the hits seen and exposes live request and error counts read off the engine. q
  # cancels: the engine stops within one pool of in-flight requests, the fiber
  # ends, and the timeout keeps any waiting `listen` from blocking on a silent
  # channel.
  class ScanSession
    getter hits : Array(Core::Response)
    getter? running : Bool
    getter error : String?
    getter target : String

    @channel : Channel(Tui::Msg)
    @cancelled : Bool
    @paused : Bool
    @mode : String
    @scan : (Hyde::Scan | Jekyll::Scan)? = nil

    def initialize(@target : String, wordlist_path : String, *, concurrency : Int32, depth : Int32, mode : String = "HYDE")
      @hits = [] of Core::Response
      @running = true
      @error = nil
      @cancelled = false
      @paused = false
      @mode = mode
      @channel = Channel(Tui::Msg).new(128)
      spawn perform(wordlist_path, concurrency, depth)
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

    private def perform(wordlist_path : String, concurrency : Int32, depth : Int32) : Nil
      validate_target!
      scan = build_scan(wordlist_path, concurrency, depth)
      @scan = scan
      scan.run(cancel: -> { @cancelled }, pause: -> { @paused }) do |response|
        @channel.send(ScanHitMsg.new(self, response)) unless @cancelled
      end
      @channel.send(ScanDoneMsg.new(self)) unless @cancelled
    rescue ex
      @channel.send(ScanFailedMsg.new(self, ex.message || "scan failed")) unless @cancelled
    end

    # Builds the engine for the mode: Jekyll fuzzes a FUZZ template with a
    # positional wordlist, Hyde recurses from the origin with a deduplicated
    # wordlist. Both stream through the same
    # `run(cancel) { }` the loop drives; the matcher/filter and depth flags are
    # the engine defaults here, with the full set exposed through the one-shot CLI.
    private def build_scan(wordlist_path : String, concurrency : Int32, depth : Int32) : Hyde::Scan | Jekyll::Scan
      if @mode == "JEKYLL"
        list = Wordlist::List.positional({wordlist_path})
        Jekyll::Scan.new(Jekyll::Template.new(@target), list, concurrency: concurrency)
      else
        list = Wordlist::List.deduplicated({wordlist_path})
        Hyde::Scan.new(@target, list, concurrency: concurrency, max_depth: depth)
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
