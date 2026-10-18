require "../render/grid"
require "../render/graphics"

# Drawing frames.
module JekyllHyde::Tui
  # Draws a cell grid, rewriting only the cells that changed since the last
  # frame, inside one synchronized update so the terminal never shows half a
  # frame. The image band is drawn over the cells and only when it moves, so the
  # kitty hologram survives untouched while the chrome around it animates.
  class Screen
    # Starts and ends a synchronized update (terminals without it ignore it).
    BEGIN_SYNC = "\e[?2026h"
    # :ditto:
    END_SYNC = "\e[?2026l"

    @previous = [] of Array(Render::Cell)
    @placement : Render::Placement? = nil
    @size = {0, 0}

    def initialize(@output : IO)
    end

    # Draws *grid*. A new size clears and redraws everything; otherwise only the
    # changed cells, and the image band only when it has moved, are written.
    def draw(grid : Render::Grid) : Nil
      full = @size != {grid.cols, grid.rows}
      frame = String.build do |io|
        io << BEGIN_SYNC
        io << "\e[2J" if full
        clear_vacated(io, grid.placement, full)
        cells(io, grid, full)
        image(io, grid, full)
        io << END_SYNC
      end
      @output << frame
      @output.flush
      @previous, @placement, @size = grid.cells, grid.placement, {grid.cols, grid.rows}
    end

    # Writes the cells that differ from the last frame. On a full redraw only the
    # non-blank cells are written (the clear took care of the rest); otherwise a
    # cell that went blank is written as a space, to erase what was there.
    private def cells(io : IO, grid : Render::Grid, full : Bool) : Nil
      grid.cells.each_with_index do |line, row|
        previous = @previous[row]?
        line.each_with_index do |cell, col|
          glyph, color, background = cell
          if full
            next if glyph == ' ' && color.nil? && background.nil?
          else
            next if previous && previous[col]? == cell
          end
          io << "\e[" << (row + 1) << ';' << (col + 1) << 'H'
          io << paint(glyph, color, background)
        end
      end
    end

    # One cell's glyph with its truecolor foreground and background, reset after
    # so the next cell starts clean. A bare glyph (no colors) is written plain.
    private def paint(glyph : Char, color : Render::RGB?, background : Render::RGB?) : String
      return glyph.to_s unless color || background
      String.build do |io|
        io << "\e[38;2;#{color[0]};#{color[1]};#{color[2]}m" if color
        io << "\e[48;2;#{background[0]};#{background[1]};#{background[2]}m" if background
        io << glyph << "\e[0m"
      end
    end

    # Draws the virtual-placement image rows, when the grid carries one and it
    # moved (the reveal grows it a row at a time) or the whole frame redrew.
    private def image(io : IO, grid : Render::Grid, full : Bool) : Nil
      placement = grid.placement
      return unless placement && (full || placement != @placement)
      placement.rows.times do |row|
        io << "\e[" << (placement.top + row + 1) << ';' << (placement.left + 1) << 'H'
        io << Render::Graphics.placeholder_row(placement.id, row, placement.width)
      end
    end

    # Overwrites, with spaces, the placeholder cells the previous image left
    # where the new frame no longer covers them, so a face that lifts or clears
    # leaves no ghost. A clear handles everything, and a growing reveal (same
    # box, more rows) vacates nothing.
    private def clear_vacated(io : IO, current : Render::Placement?, full : Bool) : Nil
      old = @placement
      return if full || old.nil? || old == current
      vacated =
        if (now = current) && now.top == old.top && now.left == old.left && now.width == old.width
          now.rows...old.rows
        else
          0...old.rows
        end
      vacated.each do |row|
        io << "\e[" << (old.top + row + 1) << ';' << (old.left + 1) << 'H' << (" " * old.width)
      end
    end
  end
end
