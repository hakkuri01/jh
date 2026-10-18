# Response body counting, one scheme per mode, kept separate because the two
# genuinely differ. Jekyll counts raw bytes; Hyde counts the decoded text. Each
# result is counted the active engine's way, once per body.
module JekyllHyde::Core::Metrics
  # Jekyll word count: 0x20 bytes plus one, over the raw body. A newline is not a
  # space, so words do not accumulate across lines.
  def self.jekyll_words(body : Bytes) : Int32
    body.count(0x20_u8) + 1
  end

  # Jekyll line count: 0x0A bytes plus one, over the raw body.
  def self.jekyll_lines(body : Bytes) : Int32
    body.count(0x0A_u8) + 1
  end

  # Hyde word count: whitespace-delimited tokens of the decoded text.
  def self.hyde_words(text : String) : Int32
    text.split.size
  end

  # Hyde line count: newline-split lines of the decoded text, dropping a trailing
  # empty line.
  def self.hyde_lines(text : String) : Int32
    text.lines.size
  end
end
