require "../render/grid"
require "../render/graphics"
require "../render/logo"
require "./hud"

# The frames the app draws.
module JekyllHyde::View
  # Builds the opener's composition into a cell grid for a given phase and time,
  # driven by the static/electric effect: the HUD rails materialize from glitch
  # inward from the corners, the face hologram wipes in top-to-bottom behind an
  # electric scan beam, the figlet wordmark glitch-flickers in beneath it, then
  # it holds; a mode switch gradient-fades the chrome through a static pass. The
  # composition shell reuses `cockpit` for its lifted-face base. Each builder is
  # pure, so the program can draw any frame at any size and a resize re-fits.
  module Scene
    extend self

    # The face's height in cells, and its kitty image id.
    LOGO_ROWS = 16
    LOGO_ID   = 73
    # The boot choreography, in seconds: HUD materialize, then the hologram
    # reveal, then the wordmark flicker, then the hold.
    HUD_ON     = 0.6
    REVEAL     = 0.6
    REVEAL_END = HUD_ON + REVEAL
    WORD_END   = REVEAL_END + 0.7
    HOLD_END   = WORD_END + 0.9
    # The electric blue of the scan beam.
    BEAM = {170, 215, 255}
    # The hold-state cheatsheet shown from the opener on, so the logo screen
    # tells the user what to do.
    HOLD_KEYS = "any key compose · tab mode · q quit"

    # The terminal and whether it shows images: everything a frame needs that is
    # not the mode or the clock.
    record Canvas, cols : Int32, rows : Int32, images : Bool

    # Where the face and the wordmark sit for a canvas.
    record Layout, top : Int32, left : Int32, width : Int32, wm_top : Int32, wm_left : Int32

    # The sequence that uploads the face once, or nothing when images are off.
    def setup(images : Bool) : String
      images ? Render::Graphics.upload(LOGO_ID, Render::Logo::PNG, image_width, LOGO_ROWS) : ""
    end

    # The sequence that frees the face on exit.
    def teardown(images : Bool) : String
      images ? Render::Graphics.delete(LOGO_ID) : ""
    end

    # The boot frame at *elapsed* seconds: the HUD reveal gives way to the full
    # HUD, the hologram grows a row at a time behind the beam, and the wordmark
    # flickers in once the face is up.
    def boot(canvas : Canvas, mode : String, elapsed : Float64) : Render::Grid
      rng = Random.new((elapsed * 120).to_i)
      layout = layout(canvas)
      grid = elapsed < HUD_ON ? reveal(canvas, mode, elapsed / HUD_ON, rng) : Hud.build(canvas.cols, canvas.rows, mode, opener_readout)
      if canvas.images && elapsed >= HUD_ON
        front = reveal_rows(elapsed)
        grid.placement = Render::Placement.new(LOGO_ID, layout.top, layout.left, layout.width, front)
        beam(grid, layout, front, rng) if front < LOGO_ROWS
      end
      wordmark(grid, layout, glitch: elapsed < WORD_END, rng: rng) if elapsed >= REVEAL_END
      grid
    end

    # The held frame: the full HUD, the full face, and the static wordmark.
    def steady(canvas : Canvas, mode : String) : Render::Grid
      boot(canvas, mode, HOLD_END)
    end

    # A static burst over a built frame: a fraction of non-blank cells flicker to
    # glitch glyphs, peaking at the midpoint. The mode-switch animation, a frame
    # transform any phase applies; it must play on every switch (a locked invariant).
    def flicker(grid : Render::Grid, progress : Float64, rng : Random) : Render::Grid
      intensity = (0.5 - (progress - 0.5).abs) * 2 * 0.5
      grid.cells.each_with_index do |line, row|
        line.each_with_index do |cell, col|
          glyph, color, background = cell
          next if glyph == ' ' && color.nil? && background.nil?
          grid.put(row, col, Render::GLITCH.sample(rng), color, background: background) if rng.rand < intensity
        end
      end
      grid
    end

    # The mode-switch frame at *progress* (0 to 1): the chrome fades from *from*
    # to *to* through a static pass, with the face and wordmark held.
    def switch(canvas : Canvas, from : String, to : String, progress : Float64) : Render::Grid
      rng = Random.new((progress * 100).to_i)
      layout = layout(canvas)
      from_accent, to_accent = Render.accent(from), Render.accent(to)
      hud_a = Hud.build(canvas.cols, canvas.rows, from, opener_readout)
      hud_b = Hud.build(canvas.cols, canvas.rows, to, opener_readout)
      grid = Render::Grid.new(canvas.cols, canvas.rows)
      hud_a.cells.each_with_index do |line, row|
        line.each_with_index do |cell, col|
          glyph, color = progress < 0.5 ? cell : hud_b.cells[row][col]
          next if glyph == ' ' && color.nil?
          color = recolor(color, from_accent, to_accent, progress)
          glyph = Render::GLITCH.sample(rng) if color && rng.rand < 0.16
          grid.put(row, col, glyph, color)
        end
      end
      grid.placement = Render::Placement.new(LOGO_ID, layout.top, layout.left, layout.width, LOGO_ROWS) if canvas.images
      wordmark(grid, layout, glitch: false, rng: rng)
      grid
    end

    # The HUD part-way through its materialize: cells resolve inward from the
    # edges, with a flickering glitch front.
    private def reveal(canvas : Canvas, mode : String, progress : Float64, rng : Random) : Render::Grid
      hud = Hud.build(canvas.cols, canvas.rows, mode, opener_readout)
      out = Render::Grid.new(canvas.cols, canvas.rows)
      front = progress * (canvas.cols / 2.0)
      hud.cells.each_with_index do |line, row|
        line.each_with_index do |cell, col|
          glyph, color = cell
          next if glyph == ' ' && color.nil?
          dist = Math.min(col, canvas.cols - 1 - col).to_f
          if dist <= front - 2
            out.put(row, col, glyph, color)
          elsif dist <= front + 1
            out.put(row, col, Render::GLITCH.sample(rng), color)
          end
        end
      end
      out
    end

    # The electric scan beam at the hologram's frontier row.
    private def beam(grid : Render::Grid, layout : Layout, front : Int32, rng : Random) : Nil
      layout.width.times do |col|
        glyph = rng.rand < 0.22 ? Render::GLITCH.sample(rng) : '━'
        grid.put(layout.top + front, layout.left + col, glyph, BEAM)
      end
    end

    # The figlet wordmark, each stacked word along the violet-to-red gradient by
    # row (JEKYLL violet, the rail magenta, HYDE red), flickering while *glitch*.
    private def wordmark(grid : Render::Grid, layout : Layout, *, glitch : Bool, rng : Random) : Nil
      art = Render::Logo::WORDMARK.lines
      art.each_with_index do |line, offset|
        color = Render::Logo.gradient(offset, art.size)
        line.each_char_with_index do |glyph, col|
          next if glyph == ' '
          shown = glitch && rng.rand < 0.3 ? Render::GLITCH.sample(rng) : glyph
          grid.put(layout.wm_top + offset, layout.wm_left + col, shown, color)
        end
      end
    end

    # An accent cell's color *progress* of the way from *from* to *to*; its dim
    # rail variant fades in step, and non-accent cells keep their color.
    private def recolor(color : Render::RGB?, from : Render::RGB, to : Render::RGB, progress : Float64) : Render::RGB?
      return color unless color
      case color
      when from                  then Render.lerp(from, to, progress)
      when Render.dim(from, 0.5) then Render.lerp(Render.dim(from, 0.5), Render.dim(to, 0.5), progress)
      else                            color
      end
    end

    # How many face rows the reveal has uncovered at *elapsed*.
    private def reveal_rows(elapsed : Float64) : Int32
      (((elapsed - HUD_ON) / REVEAL) * LOGO_ROWS).ceil.to_i.clamp(0, LOGO_ROWS)
    end

    # The centered layout for the opener's full face and wordmark.
    private def layout(canvas : Canvas) : Layout
      art = Render::Logo::WORDMARK.lines
      top = Math.max(3, (canvas.rows - (LOGO_ROWS + 1 + art.size)) // 2)
      left = Math.max((canvas.cols - image_width) // 2, 0)
      wm_left = Math.max((canvas.cols - art.max_of(&.size)) // 2, 0)
      Layout.new(top, left, image_width, top + LOGO_ROWS + 1, wm_left)
    end

    # The opener face's width in cells.
    private def image_width : Int32
      Render::Logo.cell_width(LOGO_ROWS)
    end

    # The opener's bottom-cluster readout: no vim mode yet (the header rail runs
    # straight through that slot), the ready light, and the hold cheatsheet, so
    # the HUD draw animation already shows the controls.
    private def opener_readout : Hud::Readout
      Hud::Readout.new("", false, "◉ READY", true, HOLD_KEYS)
    end
  end
end
