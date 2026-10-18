require "./value_range"
require "../core/response"

module JekyllHyde::Jekyll
  # Everything a rule can inspect about one probe: the counted response, the raw
  # body (for the regex rule), the serialized response headers (for the regex
  # rule's header matching), and how long the request took (for the time rule).
  # Assembled when a probe returns, before the keep/drop decision.
  record Candidate, response : Core::Response, body : Bytes, elapsed : Time::Span, headers : String = ""

  # One matcher/filter criterion (status, size, word, line, regex, time). A rule
  # reports whether a candidate matches it; a RuleSet combines many with and/or.
  abstract class Rule
    abstract def matches?(candidate : Candidate) : Bool

    # Build a rule by its filter name (`-mc`/`-fc` -> status, and so on).
    # Raises ArgumentError on an unknown name or a malformed value.
    def self.build(name : String, value : String) : Rule
      case name
      when "status" then StatusRule.new(value)
      when "size"   then SizeRule.new(value)
      when "word"   then WordRule.new(value)
      when "line"   then LineRule.new(value)
      when "regex"  then RegexRule.new(value)
      when "time"   then TimeRule.new(value)
      else               raise ArgumentError.new("unknown rule: #{name}")
      end
    end
  end

  # A rule over an integer metric: a comma-separated list of ValueRanges; a
  # candidate matches when the metric falls in any range. The shape behind the
  # size, word, and line filters (status adds "all", below).
  abstract class RangeRule < Rule
    @ranges : Array(ValueRange)

    def initialize(value : String)
      @ranges = value.split(',').map { |token| ValueRange.parse(token.strip) }
    end

    abstract def metric(candidate : Candidate) : Int64

    def matches?(candidate : Candidate) : Bool
      @ranges.any?(&.includes?(metric(candidate)))
    end
  end

  # Status rule (`-mc`/`-fc`): ValueRanges over the status code, or "all".
  class StatusRule < Rule
    def initialize(value : String)
      @ranges = [] of ValueRange
      @all = false
      value.split(',') do |token|
        stripped = token.strip
        stripped == "all" ? (@all = true) : (@ranges << ValueRange.parse(stripped))
      end
    end

    def matches?(candidate : Candidate) : Bool
      return true if @all
      @ranges.any?(&.includes?(candidate.response.status))
    end
  end

  # Size rule (`-ms`/`-fs`): ValueRanges over the body size in bytes.
  class SizeRule < RangeRule
    def metric(candidate : Candidate) : Int64
      candidate.response.size
    end
  end

  # Word rule (`-mw`/`-fw`): ValueRanges over the body word count.
  class WordRule < RangeRule
    def metric(candidate : Candidate) : Int64
      candidate.response.words.to_i64
    end
  end

  # Line rule (`-ml`/`-fl`): ValueRanges over the body line count.
  class LineRule < RangeRule
    def metric(candidate : Candidate) : Int64
      candidate.response.lines.to_i64
    end
  end

  # Regex rule (`-mr`/`-fr`): the pattern matched against the response headers
  # followed by the body ("Name: value\r\n" lines, then the raw body). Headers
  # arrive already valid UTF-8 from the client; the body is scrubbed to valid
  # UTF-8 first, since it is untrusted. One deliberate limit: the pattern is
  # static, with no substitution of the fuzzed input into it (so `-mr FUZZ` does
  # not match where the body echoes the current word); that would thread a
  # per-request input map through the shared pool for a niche feature, and the
  # operator can match a literal value instead.
  # ponytail: static pattern, no per-request keyword substitution; revisit only
  # if the pool grows a payload channel for another reason.
  class RegexRule < Rule
    @pattern : Regex

    def initialize(value : String)
      @pattern = compile(value)
    end

    def matches?(candidate : Candidate) : Bool
      text = candidate.headers + String.new(candidate.body).scrub
      !@pattern.match(text).nil?
    end

    private def compile(value : String) : Regex
      Regex.new(value)
    rescue
      raise ArgumentError.new("invalid regex: #{value}")
    end
  end

  # Time rule (`-mt`/`-ft`): ">N" matches a request slower than N ms, "<N"
  # one faster. Exactly one of the two prefixes is required.
  class TimeRule < Rule
    @greater : Bool
    @ms : Int64

    def initialize(value : String)
      greater = value.starts_with?('>')
      less = value.starts_with?('<')
      raise ArgumentError.new("time needs >N or <N: #{value}") unless greater ^ less
      @greater = greater
      @ms = value[1..].to_i64? || raise ArgumentError.new("time needs a number: #{value}")
    end

    def matches?(candidate : Candidate) : Bool
      ms = candidate.elapsed.total_milliseconds
      @greater ? ms > @ms : ms < @ms
    end
  end
end
