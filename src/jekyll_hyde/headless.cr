require "./scan_config"
require "./scan_builder"
require "./http/client"
require "./core/response"
require "./core/results"
require "./core/sanitize"
require "./hyde/scan"

module JekyllHyde
  # The no-TUI runner. It builds the same engine a TUI scan would (through
  # ScanBuilder, so the two cannot drift) and runs it to completion, streaming
  # one progress line per kept hit to stderr and writing the results as JSON or
  # CSV to the -o file or, with no file, to stdout. stdout stays clean data;
  # progress, warnings, and errors go to stderr; the exit code reports the
  # outcome (0 ok, 1 runtime failure), so a prepared command chains in scripts,
  # CI, and agent workflows without a terminal. Results carry no request headers,
  # cookies, or body, and every written field is sanitized by Core::Results, so
  # the same hostile-target and secret-safety guarantees as the TUI hold here.
  class Headless
    def self.run(config : ScanConfig, sink : IO = STDOUT, log : IO = STDERR) : Int32
      new(config, sink, log).run
    end

    def initialize(@config : ScanConfig, @sink : IO, @log : IO)
      @interrupted = false
    end

    def run : Int32
      scan = ScanBuilder.build(@config)
      results = with_interrupt_trap { scan.run(cancel: -> { @interrupted }) { |response| progress(response) } }
      report_warning(scan)
      code = emit(results)
      return code unless code == 0
      return 130 if @interrupted # partial results already written; 128 + SIGINT
      return report_error("every request failed; the target may be unreachable") if all_errored?(scan)
      0
    rescue ex : File::Error
      report_error("could not read wordlist: #{Core.sanitize(Path[ex.file].basename)}")
    rescue ex : ArgumentError
      report_error(Core.sanitize(ex.message || "invalid command"))
    rescue ex
      report_error(Core.sanitize(ex.message || "scan failed"))
    end

    # Run the scan with SIGINT/HUP/TERM flipping the cancel flag, so a killed run
    # stops the scan and still writes what it found (as ffuf and feroxbuster do).
    # Default handling is restored after, leaving no global signal state behind.
    private def with_interrupt_trap(&) : Core::Results
      Process.on_terminate { @interrupted = true }
      yield
    ensure
      Process.restore_interrupts!
    end

    # Every request errored on a reachable-looking run: a pipeline should see the
    # failure in the exit code, even though the written data is a valid (empty)
    # result set. A scan that simply found nothing (no errors) still exits 0.
    private def all_errored?(scan : Hyde::Scan | Jekyll::Scan) : Bool
      scan.errors > 0 && scan.errors == scan.completed
    end

    private def report_error(message : String) : Int32
      @log.puts "error: #{message}"
      1
    end

    # One line per kept hit, on stderr so stdout stays clean data. The URL is
    # remote-derived, so it is sanitized before it reaches the terminal.
    private def progress(response : Core::Response) : Nil
      @log.puts "#{response.status}  #{Core.sanitize(response.url)}"
    end

    private def report_warning(scan : Hyde::Scan | Jekyll::Scan) : Nil
      return unless scan.is_a?(Hyde::Scan)
      warning = scan.warning
      @log.puts "warning: #{Core.sanitize(warning)}" if warning
    end

    # Write the results to the -o file (atomic, via Core::Results) or, with no
    # file, to stdout. A chained command only runs after this one has exited.
    private def emit(results : Core::Results) : Int32
      if path = @config.output
        begin
          results.write(path, @config.format)
        rescue File::Error
          return report_error("could not write results to #{Core.sanitize(Path[path].basename)}")
        end
        @log.puts "wrote #{results.size} results to #{Core.sanitize(Path[path].basename)}"
      else
        @sink.puts results.serialize(@config.format)
      end
      0
    end
  end
end
