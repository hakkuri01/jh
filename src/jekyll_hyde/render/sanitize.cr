# The render-boundary sanitizer for untrusted server-derived text.
module JekyllHyde::Render
  # Replaces every control and direction-override code point with a visible `·`
  # so server text (an extracted path, a redirect target) cannot inject a
  # terminal escape, a C1 control, or a bidi reorder into the TUI. Newline and
  # tab are replaced too, not kept: results render on single cells, where either
  # would corrupt the layout. Styling is applied after this (AGENTS security).
  # One O(n) pass over bounded, already-length-capped display text.
  def self.sanitize(text : String) : String
    String.build(text.bytesize) do |io|
      text.each_char { |char| io << (printable?(char) ? char : '·') }
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
