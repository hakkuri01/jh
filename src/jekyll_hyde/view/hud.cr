require "../render/grid"
require "../version"

# The persistent cyberpunk HUD chrome.
module JekyllHyde::View
  # Builds the HUD into a cell grid: a top-left identity/mode cluster (the
  # JEKYLL // HYDE wordmark with the inactive mode greyed and the version) and a
  # bottom-right session/status cluster with branch-node readouts, each on a
  # double-layer labeled header rail and a short side rail, in one accent per
  # mode. The bottom cluster carries the vim mode, a readiness light, and the key
  # cheatsheet. The center holds the opener logo and the shell's content panel.
  module Hud
    extend self

    # The bottom-right cluster's live readouts: the header (SESSION, or the
    # shell's NORMAL/INSERT), the status light (READY, or the shell's readiness),
    # each with whether it is lit in the accent, and the key cheatsheet docked
    # onto the header rail left of the mode bracket.
    record Readout, header : String, header_on : Bool, status : String, status_on : Bool, hint : String

    def build(cols : Int32, rows : Int32, mode : String, readout : Readout) : Render::Grid
      grid = Render::Grid.new(cols, rows)
      accent = Render.accent(mode)
      top_left(grid, accent, mode, cols - 1 - header_cap(cols, readout.hint.size))
      bottom_right(grid, accent, readout)
      grid
    end

    # The top-left identity cluster: the active mode's word takes the accent, the
    # inactive one greys out. Its inner rail ends at *cap*, the mirror of the
    # bottom cluster's cap, so the two diagonals stay symmetric.
    private def top_left(grid : Render::Grid, accent : Render::RGB, mode : String, cap : Int32) : Nil
      cols, rows = grid.cols, grid.rows
      main = Math.min(cols - 2, cols * 11 // 20)
      grid.put(0, 0, '┏', accent)
      grid.rail(0, 1, main, color: accent, solid: main * 3 // 5, dir: 1)
      grid.put(1, 0, '┣', accent)
      grid.put(1, 1, '━', accent)
      grid.put(1, 2, '┤', accent)
      grid.text(1, 4, "JEKYLL", mode == "JEKYLL" ? accent : Render::MUTED)
      grid.text(1, 11, "∕∕", accent)
      grid.text(1, 14, "HYDE", mode == "HYDE" ? accent : Render::MUTED)
      version = "· v#{JekyllHyde::VERSION}"
      grid.text(1, 19, version, Render::MUTED)
      close = 20 + version.size
      grid.put(1, close, '├', accent)
      len = Math.max(cap - close, 3)
      grid.rail(1, close + 1, len, color: accent, solid: len * 3 // 5, dir: 1)
      grid.vrail(2, 0, Math.min(rows - 3, rows * 2 // 5), color: accent, solid: 5, dir: 1)
    end

    private def bottom_right(grid : Render::Grid, accent : Render::RGB, readout : Readout) : Nil
      cols, rows = grid.cols, grid.rows
      edge = cols - 1
      main = Math.min(cols - 2, cols * 11 // 20)
      grid.put(rows - 1, edge, '┛', accent)
      grid.rail(rows - 1, edge - 1, main, color: accent, solid: main * 3 // 5, dir: -1)
      header_rail(grid, accent, readout)
      grid.vrail(rows - 3, edge, Math.min(rows - 3, rows * 2 // 5), color: accent, solid: 5, dir: -1)
      return if readout.status.empty?
      grid.branch(rows - 4, edge, tee: '┨', dir: -1, color: accent)
      grid.rtext(rows - 4, edge - 4, readout.status, readout.status_on ? accent : Render::MUTED)
    end

    # The header rail: a `┤ cheatsheet ├` and, in the cockpit, a `┤ NORMAL/INSERT ├`
    # mode bracket, running solid from the `┫` corner out to a `▰▰▱` cap. The bottom
    # is the reference for the diagonal; the top mirrors `header_cap`.
    private def header_rail(grid : Render::Grid, accent : Render::RGB, readout : Readout) : Nil
      cols, row, edge = grid.cols, grid.rows - 2, grid.cols - 1
      rail = Render.dim(accent, 0.5)
      slot = 6
      mode_open = edge - slot - 5
      grid.put(row, edge, '┫', accent)
      if readout.header.empty?
        (mode_open..edge - 1).each { |col| grid.put(row, col, '━', accent) }
      else
        bracket(grid, row, mode_open, readout.header, label_color: readout.header_on ? accent : Render::TEXT, accent: accent)
        ((mode_open + 4 + readout.header.size)..(edge - 1)).each { |col| grid.put(row, col, '━', accent) }
      end
      3.times { |offset| grid.put(row, mode_open - 1 - offset, '━', accent) }
      cheat_open = mode_open - 4 - readout.hint.size - 3
      bracket(grid, row, cheat_open, readout.hint, label_color: Render::MUTED, accent: accent)
      cap = header_cap(cols, readout.hint.size)
      (cap + 3...cheat_open).each { |col| grid.put(row, col, '╍', rail) }
      {'▰', '▰', '▱'}.each_with_index { |glyph, offset| grid.put(row, cap + 2 - offset, glyph, accent) }
    end

    # The bottom cluster's inner-rail `▱` cap column, pulled left of the cheatsheet
    # when one would overlap. The top cluster mirrors this (`cols - 1 - header_cap`)
    # so the two diagonals stay symmetric at any width, a locked invariant.
    private def header_cap(cols : Int32, hint : Int32) : Int32
      edge = cols - 1
      cheat_open = edge - 18 - hint
      label = Math.min(cols - 21, cols * 2 // 5)
      Math.min(edge - 19 - label, cheat_open - 4)
    end

    # `┤ label ├` opening at column *open*: the bracket, a space, the label, a
    # space, the closing bracket.
    private def bracket(grid : Render::Grid, row : Int32, open : Int32, label : String, *, label_color : Render::RGB, accent : Render::RGB) : Nil
      grid.put(row, open, '┤', accent)
      grid.text(row, open + 2, label, label_color)
      grid.put(row, open + 3 + label.size, '├', accent)
    end
  end
end
