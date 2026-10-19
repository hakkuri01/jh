require "./rule"

module JekyllHyde::Jekyll
  # The matcher/filter decision. A response is kept when the matchers accept it
  # and the filters do not reject it. Each side combines its rules with a mode:
  # "or" (any) or "and" (all). For matchers that is accept-if-any /
  # accept-only-if-all; for filters it is reject-if-any / reject-only-if-all. Both
  # modes default to "or", with one default status matcher and no filters.
  class Rules
    enum Mode
      Or
      And
    end

    # The default `--mc`: the whole 2xx range, not just 200/204 (an older default).
    DEFAULT_STATUS = "200-299,301,302,307,401,403,405,500"

    def initialize(@matchers : Array(Rule), @filters : Array(Rule) = [] of Rule, *, @matcher_mode : Mode = Mode::Or, @filter_mode : Mode = Mode::Or)
    end

    # The default: the default status matcher, no filters, or/or.
    def self.default : Rules
      new([Rule.build("status", DEFAULT_STATUS)])
    end

    # Whether *candidate* is kept: accepted by the matchers and not rejected by
    # the filters.
    def keep?(candidate : Candidate) : Bool
      accepts?(candidate) && !rejects?(candidate)
    end

    # Whether the matchers accept *candidate*. With no matchers nothing is
    # accepted (a default status matcher is installed, so this holds only if the
    # caller clears it deliberately).
    def accepts?(candidate : Candidate) : Bool
      return false if @matchers.empty?
      case @matcher_mode
      in Mode::And then @matchers.all?(&.matches?(candidate))
      in Mode::Or  then @matchers.any?(&.matches?(candidate))
      end
    end

    # Whether the filters reject *candidate*. With no filters nothing is rejected.
    def rejects?(candidate : Candidate) : Bool
      return false if @filters.empty?
      case @filter_mode
      in Mode::And then @filters.all?(&.matches?(candidate))
      in Mode::Or  then @filters.any?(&.matches?(candidate))
      end
    end

    # A copy with *extra* filters appended, the matchers and modes unchanged;
    # autocalibration folds its learned wildcard filters in this way.
    def with_filters(extra : Array(Rule)) : Rules
      Rules.new(@matchers, @filters + extra, matcher_mode: @matcher_mode, filter_mode: @filter_mode)
    end
  end
end
