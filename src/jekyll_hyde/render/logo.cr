require "./graphics"

# The Jekyll // Hyde logo.
module JekyllHyde::Render
  # The comedy/tragedy split mask over the figlet wordmark. The mask is the real
  # artwork (data/logo/logo.png) shown over the kitty graphics protocol where the
  # terminal supports it; the wordmark (data/logo/wordmark.txt) sits beneath it,
  # colored violet Jekyll to red Hyde, and stands alone where there are no
  # images. Both are baked and embedded at compile time.
  module Logo
    # The baked, transparent mask artwork.
    PNG = {{ read_file("#{__DIR__}/../../../data/logo/logo.png") }}.to_slice
    # The figlet wordmark: the two words stacked over a rail separator (JEKYLL,
    # then ━…╍…▰▰▱, then HYDE), colored violet-to-red down the rows.
    WORDMARK = {{ read_file("#{__DIR__}/../../../data/logo/wordmark.txt") }}
    # The mask's height in cells on the loading screen and the banner.
    DEFAULT_ROWS = 18
    # Jekyll violet and Hyde red; the wordmark runs a gradient between them.
    VIOLET = {176, 96, 232}
    RED    = {240, 48, 72}

    # The banner: the mask image (when *images*) above the wordmark, else the
    # wordmark alone. *rows* is the image's height in cells.
    def self.banner(images : Bool, rows : Int32 = DEFAULT_ROWS) : String
      String.build do |io|
        io << image(rows) if images
        io << '\n' << wordmark << '\n'
      end
    end

    # The wordmark, each stacked word colored along the violet-to-red gradient by
    # row: JEKYLL violet at the top, the rail magenta, HYDE red at the bottom.
    def self.wordmark : String
      lines = WORDMARK.lines
      String.build do |io|
        lines.each_with_index do |line, row|
          color = gradient(row, lines.size)
          line.each_char { |glyph| io << (glyph == ' ' ? " " : paint(glyph, color)) }
          io << '\n'
        end
      end
    end

    # The kitty-graphics image placed at the cursor, with the cursor stepped
    # below it to a clean line.
    private def self.image(rows : Int32) : String
      String.build do |io|
        io << '\n' << Graphics.image(PNG, cell_width(rows), rows)
        io << "\e[" << rows << "B\r"
      end
    end

    # The image's width in cells for a *rows*-tall box, matching the artwork's
    # aspect over cells that are about twice as tall as wide.
    def self.cell_width(rows : Int32) : Int32
      width, height = pixels
      (rows * 2 * width / height).round.to_i
    end

    # The artwork's {width, height} in pixels, from its PNG header.
    def self.pixels : {Int32, Int32}
      {read_u32(16), read_u32(20)}
    end

    # The big-endian UInt32 at byte *at* of the PNG.
    private def self.read_u32(at : Int32) : Int32
      (PNG[at].to_i << 24) | (PNG[at + 1].to_i << 16) | (PNG[at + 2].to_i << 8) | PNG[at + 3].to_i
    end

    # The gradient color at *index* of *span*: violet at 0, red at the end. Used
    # across columns or down rows, so the wordmark can run it either way.
    def self.gradient(index : Int32, span : Int32) : {Int32, Int32, Int32}
      f = span <= 1 ? 0.0 : index / (span - 1).to_f
      {lerp(VIOLET[0], RED[0], f), lerp(VIOLET[1], RED[1], f), lerp(VIOLET[2], RED[2], f)}
    end

    # *a* moved *f* (0 to 1) of the way to *b*.
    private def self.lerp(a : Int32, b : Int32, f : Float64) : Int32
      (a + (b - a) * f).round.to_i
    end

    # *char* in truecolor *rgb*.
    private def self.paint(char : Char, rgb : {Int32, Int32, Int32}) : String
      "\e[38;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m#{char}\e[0m"
    end
  end
end
