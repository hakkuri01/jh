require "../../spec_helper"
require "../../../src/jekyll_hyde/tui/screen"

# A one-row grid of *width* with a single glyph at column 1.
private def one_cell(width : Int32, glyph : Char) : JekyllHyde::Render::Grid
  grid = JekyllHyde::Render::Grid.new(width, 1)
  grid.put(0, 1, glyph, JekyllHyde::Render::HYDE)
  grid
end

describe JekyllHyde::Tui::Screen do
  it "clears and positions every non-blank cell on the first frame" do
    io = IO::Memory.new
    JekyllHyde::Tui::Screen.new(io).draw(one_cell(3, 'X'))
    out = io.to_s
    out.should contain("\e[?2026h")
    out.should contain("\e[2J")
    out.should contain("\e[1;2H")
    out.should contain("X")
  end

  it "redraws only changed cells once the size holds" do
    io = IO::Memory.new
    screen = JekyllHyde::Tui::Screen.new(io)
    screen.draw(one_cell(3, 'X'))
    io.clear
    screen.draw(one_cell(3, 'Y'))
    out = io.to_s
    out.should contain("Y")
    out.should_not contain("\e[2J")
  end

  it "draws the image band when the grid carries a placement" do
    io = IO::Memory.new
    grid = JekyllHyde::Render::Grid.new(10, 5)
    grid.placement = JekyllHyde::Render::Placement.new(id: 73, top: 1, left: 2, width: 4, rows: 2)
    JekyllHyde::Tui::Screen.new(io).draw(grid)
    io.to_s.should contain("\e[38;5;73m")
  end
end
