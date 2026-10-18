# Terminal cell grid and the box-drawing primitives views draw with. A grid is a
# rectangle of {glyph, foreground, background} cells; the screen writes only the
# non-blank ones, so a placed image and untouched regions survive between frames.
# The background lets content panels paint a selection wash, for the GUI feel.
module JekyllHyde::Render
  alias RGB = Tuple(Int32, Int32, Int32)
  alias Cell = Tuple(Char, RGB?, RGB?)

  # Hyde red, Jekyll violet, and the neutral greys the HUD text uses.
  HYDE   = {240, 48, 72}
  JEKYLL = {176, 96, 232}
  TEXT   = {205, 210, 225}
  MUTED  = {120, 122, 150}
  # The lifted panel interior behind an unfocused input well, a hair off black
  # with a cool tint, so a well reads as an inset field on the card.
  SURFACE = {26, 24, 40}
  # Glyphs the static/electric effect flickers through.
  GLITCH = "/\\|=+*#%<>[]".chars

  # The accent for *mode*.
  def self.accent(mode : String) : RGB
    mode == "JEKYLL" ? JEKYLL : HYDE
  end

  # *rgb* scaled by *factor* toward black.
  def self.dim(rgb : RGB, factor : Float64) : RGB
    {(rgb[0] * factor).to_i, (rgb[1] * factor).to_i, (rgb[2] * factor).to_i}
  end

  # *a* moved *factor* (0 to 1) of the way to *b*, per channel.
  def self.lerp(a : RGB, b : RGB, factor : Float64) : RGB
    {
      (a[0] + (b[0] - a[0]) * factor).round.to_i,
      (a[1] + (b[1] - a[1]) * factor).round.to_i,
      (a[2] + (b[2] - a[2]) * factor).round.to_i,
    }
  end

  # Where a virtual-placement image sits in a frame: its kitty id, its top-left
  # cell, its width in cells, and how many rows from the top are shown (the
  # hologram reveals from zero up to the full height).
  record Placement, id : Int32, top : Int32, left : Int32, width : Int32, rows : Int32

  # A rectangle of cells addressed by 0-based row and column, with an optional
  # image band the screen draws over the cells.
  class Grid
    getter cols : Int32
    getter rows : Int32
    getter cells : Array(Array(Cell))
    property placement : Placement? = nil

    def initialize(@cols : Int32, @rows : Int32)
      @cells = Array.new(@rows) { Array.new(@cols) { {' ', nil.as(RGB?), nil.as(RGB?)} } }
    end

    def put(row : Int32, col : Int32, glyph : Char, color : RGB?, background : RGB? = nil) : Nil
      return unless 0 <= row < @rows && 0 <= col < @cols
      @cells[row][col] = {glyph, color, background}
    end

    def text(row : Int32, col : Int32, str : String, color : RGB?, background : RGB? = nil) : Nil
      str.each_char_with_index { |glyph, offset| put(row, col + offset, glyph, color, background) }
    end

    # *str* placed so its last character sits at column *endcol*.
    def rtext(row : Int32, endcol : Int32, str : String, color : RGB?, background : RGB? = nil) : Nil
      text(row, endcol - str.size + 1, str, color, background)
    end

    # Paints *background* across *len* cells from *col*, keeping each cell's
    # glyph and foreground: a selection wash over a row of content.
    def wash(row : Int32, col : Int32, len : Int32, background : RGB) : Nil
      len.times do |offset|
        at = col + offset
        next unless 0 <= row < @rows && 0 <= at < @cols
        glyph, color, _ = @cells[row][at]
        @cells[row][at] = {glyph, color, background}
      end
    end

    # A horizontal rail: heavy and bright for *solid* cells, then dashed and
    # dimmed toward the center, ending in a lit ▰▰▱ cap.
    def rail(row : Int32, col : Int32, len : Int32, *, color : RGB, solid : Int32, dir : Int32) : Nil
      len.times do |offset|
        at = col + offset * dir
        if offset >= len - 3
          put(row, at, offset == len - 1 ? '▱' : '▰', color)
        elsif offset < solid
          put(row, at, '━', color)
        else
          put(row, at, '╍', Render.dim(color, 0.5))
        end
      end
    end

    # A vertical side rail: heavy for *solid*, then dashed and dimmed.
    def vrail(row : Int32, col : Int32, len : Int32, *, color : RGB, solid : Int32, dir : Int32) : Nil
      len.times do |offset|
        put(row + offset * dir, col, offset < solid ? '┃' : '┇', offset < solid ? color : Render.dim(color, 0.5))
      end
    end

    # A branch node (┠─◈ or ◈─┨) hanging off a side rail.
    def branch(row : Int32, col : Int32, *, tee : Char, dir : Int32, color : RGB) : Nil
      put(row, col, tee, color)
      put(row, col + dir, '─', color)
      put(row, col + 2 * dir, '◈', color)
    end
  end
end
