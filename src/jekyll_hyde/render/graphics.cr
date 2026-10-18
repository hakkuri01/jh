require "base64"

# Terminal images over the kitty graphics protocol.
module JekyllHyde::Render
  # Shows images in terminals that speak the kitty graphics protocol (Ghostty
  # and kitty). Two placements: direct (the one-shot banner draws the image at
  # the cursor) and virtual (the opener uploads once and reveals it a row at a
  # time via Unicode placeholder cells, for the hologram materialize).
  module Graphics
    # The most base64 one escape sequence carries.
    CHUNK = 4096
    # The kitty Unicode image placeholder.
    PLACEHOLDER = '\u{10EEEE}'
    # The combining marks that number placeholder rows and columns, in protocol
    # order (the start of the kitty rowcolumn list, enough for the logo).
    DIACRITICS = [
      '\u0305', '\u030D', '\u030E', '\u0310', '\u0312', '\u033D', '\u033E', '\u033F',
      '\u0346', '\u034A', '\u034B', '\u034C', '\u0350', '\u0351', '\u0352', '\u0357',
      '\u035B', '\u0363', '\u0364', '\u0365', '\u0366', '\u0367', '\u0368', '\u0369',
      '\u036A', '\u036B', '\u036C', '\u036D', '\u036E', '\u036F', '\u0483', '\u0484',
      '\u0485', '\u0486', '\u0487', '\u0592', '\u0593', '\u0594', '\u0595', '\u0597',
      '\u0598', '\u0599', '\u059C', '\u059D', '\u059E', '\u059F', '\u05A0', '\u05A1',
    ]

    # Whether the terminal shows images: Ghostty or kitty, outside tmux, which
    # would need its own graphics passthrough.
    def self.images?(env : Hash(String, String) | ENV.class = ENV) : Bool
      !env.has_key?("TMUX") && (env["TERM_PROGRAM"]? == "ghostty" || env["TERM"]? == "xterm-kitty")
    end

    # The sequence that transmits *png* and displays it in a *columns* by *rows*
    # cell box at the cursor, leaving the cursor where it started (C=1).
    def self.image(png : Bytes, columns : Int32, rows : Int32) : String
      chunked(png) { |first| first ? "a=T,f=100,t=d,C=1,c=#{columns},r=#{rows},q=2," : "" }
    end

    # The sequence that transmits *png* as image *id* with a *columns* by *rows*
    # virtual placement, asking for no replies. Nothing shows until a row is
    # emitted with `placeholder_row`.
    def self.upload(id : Int32, png : Bytes, columns : Int32, rows : Int32) : String
      chunked(png) { |first| first ? "a=T,U=1,f=100,t=d,i=#{id},c=#{columns},r=#{rows},q=2," : "" }
    end

    # Row *row* of image *id*'s placeholder cells, *columns* wide: the id in the
    # foreground (a 256-color index), each cell's row and column in its diacritics.
    def self.placeholder_row(id : Int32, row : Int32, columns : Int32) : String
      String.build do |io|
        io << "\e[38;5;" << id << 'm'
        columns.times { |col| io << PLACEHOLDER << DIACRITICS[row] << DIACRITICS[col] }
        io << "\e[0m"
      end
    end

    # The sequence that deletes image *id* and frees its data (opener teardown).
    def self.delete(id : Int32) : String
      "\e_Ga=d,d=I,i=#{id},q=2\e\\"
    end

    # Base64-chunks *png* into graphics escapes; *keys* yields the control keys
    # for the first chunk.
    private def self.chunked(png : Bytes, &keys : Bool -> String) : String
      encoded = Base64.strict_encode(png)
      String.build do |io|
        (0...encoded.size).step(CHUNK).each_with_index do |start, index|
          last = start + CHUNK >= encoded.size
          io << "\e_G" << keys.call(index == 0)
          io << "m=" << (last ? 0 : 1) << ';' << encoded[start, CHUNK] << "\e\\"
        end
      end
    end
  end
end
