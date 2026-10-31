require "../wordlist/list"
require "./template"

module JekyllHyde::Jekyll
  # One `-w list:KEYWORD` pairing: the keyword the template carries and the
  # wordlist that fills it.
  record Source, keyword : String, list : Wordlist::List do
    # Split a "-w" spec into path and keyword: "path:KEYWORD", or a bare "path"
    # defaulting to FUZZ. The last colon splits (a scheme or drive colon is kept;
    # a leading colon is not a separator). Hyde takes the path, ignores the keyword.
    def self.split(spec : String) : {String, String}
      if (idx = spec.rindex(':')) && idx > 0
        {spec[0...idx], spec[(idx + 1)..]}
      else
        {spec, Template::KEYWORD}
      end
    end
  end

  # Multi-wordlist input modes over one or more keyword/wordlist sources.
  # Clusterbomb walks every combination with the first source varying fastest (an
  # odometer order); pitchfork walks the sources in lockstep, wrapping a shorter
  # list back to its start until the longest is spent. Each step is a keyword =>
  # value map the template fills. Combinations are generated on demand, never
  # materialized, so a large clusterbomb product stays O(sources) in space.
  class Input
    include Enumerable(Hash(String, String))

    enum Mode
      Clusterbomb
      Pitchfork
    end

    getter mode : Mode

    def initialize(@sources : Array(Source), @mode : Mode = Mode::Clusterbomb)
      raise ArgumentError.new("a Jekyll scan needs at least one wordlist") if @sources.empty?
      raise ArgumentError.new("every wordlist needs a keyword") if @sources.any?(&.keyword.empty?)
      # Reject two wordlists bound to the same keyword. One injection point can
      # carry one value per request, so a second binding could only shadow the
      # first: the run would walk the full product while one list's entries never
      # reach the wire. Refusing beats silently dropping a list that was asked for.
      keywords.tally.each do |keyword, count|
        raise ArgumentError.new("two wordlists are bound to #{keyword}; give each -w a distinct FILE:KEYWORD") if count > 1
      end
    end

    def keywords : Array(String)
      @sources.map(&.keyword)
    end

    # The combinations this mode produces: the product of list sizes (clusterbomb)
    # or the longest list (pitchfork); zero if any source is empty. Int64, since a
    # clusterbomb product overflows Int32 well before it is unreasonable.
    def total : Int64
      return 0_i64 if @sources.any?(&.list.empty?)
      case @mode
      in Mode::Clusterbomb then @sources.reduce(1_i64) { |n, source| n * source.list.size }
      in Mode::Pitchfork   then @sources.max_of(&.list.size).to_i64
      end
    end

    # Yields each combination as a keyword => value map. Nothing is yielded when a
    # source is empty.
    def each(& : Hash(String, String) ->) : Nil
      return if @sources.any?(&.list.empty?)
      case @mode
      in Mode::Clusterbomb then each_clusterbomb { |values| yield values }
      in Mode::Pitchfork   then each_pitchfork { |values| yield values }
      end
    end

    # Cartesian product, first source varying fastest: a mixed-radix odometer
    # whose digit 0 (the first source) increments first and carries upward: the
    # clusterbomb emission order.
    private def each_clusterbomb(& : Hash(String, String) ->) : Nil
      indices = Array.new(@sources.size, 0)
      loop do
        yield combination(indices)
        carry = 0
        while carry < indices.size
          indices[carry] += 1
          break if indices[carry] < @sources[carry].list.size
          indices[carry] = 0
          carry += 1
        end
        break if carry == indices.size
      end
    end

    # Lockstep, wrapping a shorter list modulo its length until the longest list
    # is spent: the pitchfork order.
    private def each_pitchfork(& : Hash(String, String) ->) : Nil
      @sources.max_of(&.list.size).times do |step|
        values = {} of String => String
        @sources.each do |source|
          entries = source.list.entries
          values[source.keyword] = entries[step % entries.size]
        end
        yield values
      end
    end

    private def combination(indices : Array(Int32)) : Hash(String, String)
      values = {} of String => String
      @sources.each_with_index do |source, i|
        values[source.keyword] = source.list.entries[indices[i]]
      end
      values
    end
  end
end
