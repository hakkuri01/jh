require "../tui/model"
require "../tui/message"
require "../core/response"
require "../core/results"
require "../http/client"
require "../hyde/scan"
require "../jekyll/scan"
require "../scan_builder"
require "../scan_config"

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
        when msg = channel.receive?
          # nil means the channel closed on cancel; a tick is harmless (the app
          # ignores it for the superseded session). .as widens both arms to Tui::Msg.
          msg || ScanTickMsg.new(session).as(Tui::Msg)
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
      # Wake a scan fiber parked in a full-channel send: with the UI no longer
      # pulling results, that send would never return and the whole request pool
      # and its sockets would stay parked for the process life. Closing makes the
      # parked send raise, which the pool turns into a clean drain.
      @channel.close
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
      scan = ScanBuilder.build(@config)
      @scan = scan
      results = scan.run(cancel: -> { @cancelled }, pause: -> { @paused }) do |response|
        @channel.send(ScanHitMsg.new(self, response)) unless @cancelled
      end
      # Export whatever was found, even when q stopped the scan early: the hits
      # are real and the operator asked for an -o file, so stopping should cost
      # the rest of the scan, not the part that already succeeded.
      @export_warning = export(results)
      @channel.send(ScanDoneMsg.new(self)) unless @cancelled
    rescue ex : File::Error
      # A wordlist that cannot be read: one clean line, no absolute path
      # (AGENTS Security 7). The export path's own failures are handled in export.
      @channel.send(ScanFailedMsg.new(self, "could not read wordlist: #{Path[ex.file].basename}")) unless @cancelled
    rescue ex
      @channel.send(ScanFailedMsg.new(self, ex.message || "scan failed")) unless @cancelled
    end

    # Write the results to the -o path when one is set and the scan finished on
    # its own, returning a one-line notice if the write fails (the hits are
    # already on the dashboard, so a bad path is surfaced, not fatal).
    private def export(results : Core::Results) : String?
      path = @config.output
      return nil unless path
      begin
        results.write(path, @config.format)
        nil
      rescue File::Error
        # No absolute path in the message (AGENTS Security 7); on-screen results stay.
        "could not write results to #{Path[path].basename}"
      end
    end
  end
end
