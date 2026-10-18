# A small parity scorer for the engine parity-run specs. A scenario pairs the
# findings jh produced with an independent expected set, hand-authored for each
# route tree (the offline gate derives the oracle by hand). The score is the
# Jaccard agreement across all scenarios: 1.0 only when jh has no missing and no
# extra findings anywhere, so both a false negative and a false positive pull it
# down.
module Parity
  record Scenario, name : String, expected : Set(String), actual : Set(String) do
    # Expected but not found: a false negative.
    def missing : Set(String)
      expected - actual
    end

    # Found but not expected: a false positive.
    def extra : Set(String)
      actual - expected
    end

    def clean? : Bool
      missing.empty? && extra.empty?
    end
  end

  # The agreement ratio over every scenario: sum of intersections over sum of
  # unions.
  def self.score(scenarios : Enumerable(Scenario)) : Float64
    agree = scenarios.sum { |s| (s.expected & s.actual).size }
    total = scenarios.sum { |s| (s.expected | s.actual).size }
    total.zero? ? 1.0 : agree / total.to_f
  end

  # One line per diverging scenario, the recorded diff for the spec log.
  def self.report(scenarios : Enumerable(Scenario)) : String
    lines = scenarios.reject(&.clean?).map do |s|
      "  [#{s.name}] missing=#{s.missing.to_a.sort} extra=#{s.extra.to_a.sort}"
    end
    lines.empty? ? "  (full parity, no divergences)" : lines.join("\n")
  end
end
