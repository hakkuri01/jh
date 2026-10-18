# ValueRange, the shared unit behind the status, size, word, and line matchers
# and filters.
module JekyllHyde::Jekyll
  # An inclusive integer range: "200" parses to 200..200, "200-299" to 200..299
  # (the minimum must be strictly below the maximum). Int64, to hold a response
  # size.
  record ValueRange, min : Int64, max : Int64 do
    RANGE = /\A(\d+)-(\d+)\z/

    # Parse one range token. Raises ArgumentError on a non-number or an
    # inverted range, the clean message the caller surfaces.
    def self.parse(text : String) : ValueRange
      if m = RANGE.match(text)
        min = m[1].to_i64? || raise ArgumentError.new("not a number: #{m[1]}")
        max = m[2].to_i64? || raise ArgumentError.new("not a number: #{m[2]}")
        raise ArgumentError.new("range minimum must be below its maximum: #{text}") if min >= max
        new(min, max)
      else
        value = text.to_i64? || raise ArgumentError.new("not a number: #{text}")
        new(value, value)
      end
    end

    def includes?(value : Int) : Bool
      min <= value <= max
    end
  end
end
