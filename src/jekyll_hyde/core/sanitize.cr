# The shared sanitizer for untrusted server-derived text, the one home for the
# "is this byte safe to emit" predicate (AGENTS Security 9). Used at both
# boundaries a hostile response can reach: the terminal (the results view) and
# the filesystem (an export file).
module JekyllHyde::Core
  # Replaces every control and direction-override code point with a visible `·`
  # so server text (an extracted path, a redirect target) cannot inject a
  # terminal escape, a C1 control, or a bidi reorder into the TUI or a file.
  # Newline and tab are replaced too, not kept: results render on single cells,
  # where either would corrupt the layout. Styling is applied after this.
  # One O(n) pass over bounded, already-length-capped text.
  def self.sanitize(text : String) : String
    String.build(text.bytesize) do |io|
      text.each_char { |char| io << (printable?(char) ? char : '·') }
    end
  end

  # Sanitize at most *limit* characters, stopping early. A caller that will only
  # show *limit* cells never pays for a pathologically long line, so a per-frame
  # render stays O(cells drawn), not O(line) (AGENTS Big O). One forward pass,
  # bounded by *limit*; sanitizing is 1:1 on characters, so the cap is exact.
  def self.sanitize(text : String, limit : Int32) : String
    return "" if limit <= 0
    String.build do |io|
      count = 0
      text.each_char do |char|
        break if count >= limit
        io << (printable?(char) ? char : '·')
        count += 1
      end
    end
  end

  # A character safe to place in a cell: not a C0 control (ESC, newline, tab
  # among them), not DEL, not a C1 control, not a bidi embedding, override, or
  # isolate that could reorder a line.
  private def self.printable?(char : Char) : Bool
    code = char.ord
    return false if code < 0x20 || code == 0x7F
    return false if 0x80 <= code <= 0x9F
    return false if 0x202A <= code <= 0x202E
    return false if 0x2066 <= code <= 0x2069
    true
  end
end
