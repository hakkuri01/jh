require "../core/results"
require "../core/response"
require "../http/client"
require "../http/pool"
require "../wordlist/list"
require "./calibration"
require "./input"
require "./rules"
require "./template"

module JekyllHyde::Jekyll
  # A lazy stream of request paths: each input combination substituted into the
  # template, generated on demand so a large clusterbomb product is never
  # materialized. The pool pulls paths under backpressure.
  private struct PathStream
    include Enumerable(String)

    def initialize(@input : Input, @template : Template)
    end

    def each(& : String ->) : Nil
      @input.each { |values| yield @template.path(values) }
    end
  end

  # Flat fuzzing: substitute each input combination into the FUZZ template,
  # request them over the pool against the single origin, count each body the
  # Jekyll way, and keep the responses the matcher/filter rules accept. No
  # recursion and no link extraction: Jekyll is precise, scoped fuzzing, not
  # discovery. One run per instance.
  class Scan
    @results = Core::Results.new
    @on_result : Proc(Core::Response, Nil)? = nil
    @cancel : Proc(Bool)? = nil
    @pause : Proc(Bool)? = nil
    # Live progress, read by the TUI from another fiber; safe under the
    # single-thread scheduler (written on the scan fiber, read on the UI fiber,
    # both at yield points, and a plain Int32 read never tears).
    getter completed = 0
    getter errors = 0

    def initialize(@template : Template, @input : Input, @options : Http::Options = Http::Options.jekyll, *, concurrency : Int32 = 40, @rules : Rules = Rules.default, auto_calibrate : Bool = false)
      @concurrency = concurrency
      @auto_calibrate = auto_calibrate
    end

    # Convenience: one wordlist bound to the default FUZZ keyword (a clusterbomb
    # of a single source), the common single-keyword scan.
    def self.new(template : Template, wordlist : Wordlist::List, options : Http::Options = Http::Options.jekyll, *, concurrency : Int32 = 40, rules : Rules = Rules.default, auto_calibrate : Bool = false) : Scan
      new(template, Input.new([Source.new(Template::KEYWORD, wordlist)]), options, concurrency: concurrency, rules: rules, auto_calibrate: auto_calibrate)
    end

    # Run to completion, returning every kept result.
    def run : Core::Results
      perform
    end

    # Stream each kept result to *on_result* as it is found, stopping early when
    # *cancel* returns true and holding while *pause* returns true (both checked
    # as the pool feeds, so each takes effect within one pool of in-flight
    # requests): the TUI streams results into the Elm loop, q stops the scan, and
    # p holds it without leaving requests hammering the target.
    def run(cancel : Proc(Bool)? = nil, pause : Proc(Bool)? = nil, &on_result : Core::Response ->) : Core::Results
      @on_result = on_result
      @cancel = cancel
      @pause = pause
      perform
    end

    private def perform : Core::Results
      rules = @auto_calibrate ? calibrated_rules : @rules
      paths = PathStream.new(@input, @template)
      Http::Pool.new(@template.origin, @options, @concurrency).run(paths, @cancel, @pause) { |job| handle(job, rules) }
      @results
    end

    # Runs autocalibration first and folds any learned wildcard filters into the
    # rules; the learned set is empty (and the rules unchanged) on a well-behaved
    # 404 host.
    private def calibrated_rules : Rules
      learned = Calibration.new(@template, @rules, @options, @concurrency).learn
      learned.empty? ? @rules : @rules.with_filters(learned)
    end

    private def handle(job : Http::Job, rules : Rules) : Nil
      outcome = job.outcome
      @completed += 1
      @errors += 1 unless outcome
      return unless outcome
      response = Core::Response.jekyll("#{@template.origin}#{job.path}", outcome.status, outcome.body, outcome.location)
      candidate = Candidate.new(response, outcome.body, outcome.duration, outcome.headers)
      return unless rules.keep?(candidate)
      @results << response
      @on_result.try &.call(response)
    end
  end
end
