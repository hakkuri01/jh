require "../render/grid"
require "./hud"
require "./scene"
require "./text"

# The in-TUI command reference.
module JekyllHyde::View
  # The `h` page: the universal keys and flags on top, and a mode-only panel
  # below that Tab flips between Hyde and Jekyll (the switch animation plays, as
  # everywhere). A pure renderer in the HUD chrome; the App owns the phase.
  module Help
    extend self

    HELP_KEYS = "tab mode · h/q back"

    # {key or flag, what it does}. The two universal panels read the same in both
    # modes; the mode panel below changes with the active engine.
    KEYS = [
      {"j/k ↑/↓", "move between fields"},
      {"i", "edit the field"},
      {"/", "preview the wordlist (on -w)"},
      {"enter", "run the scan"},
      {"tab", "switch the mode"},
      {"h", "toggle this help"},
      {"q", "quit / step back"},
      {"esc", "leave INSERT mode"},
    ]
    FLAGS = [
      {"-u", "target URL"},
      {"-w", "wordlist path"},
      {"-e", "extensions (php,html,…)"},
      {"-t", "concurrent threads"},
      {"--mc", "match status codes"},
      {"--fc", "filter status codes"},
    ]
    HYDE = [
      {"-d", "max recursion depth"},
      {"--no-recursion", "scan only the target, no descent"},
      {"--auto-tune", "back off on 429/403 floods"},
      {"native", "recursion · calibration · link scrape"},
    ]
    JEKYLL = [
      {"FUZZ", "injection keyword, required in -u"},
      {"input", "clusterbomb · pitchfork (multi -w)"},
      {"--ms --mw --ml", "match size · words · lines"},
      {"--mr --mt", "match regex · time (--f… to filter)"},
      {"and/or", "combine matchers and filters"},
    ]

    # The reference frame for *mode*: KEYS and FLAGS side by side, then the
    # mode-only panel full width in the accent.
    def frame(canvas : Scene::Canvas, mode : String) : Render::Grid
      readout = Hud::Readout.new("HELP", true, "", false, HELP_KEYS)
      grid = Hud.build(canvas.cols, canvas.rows, mode, readout)
      left = 4
      right = canvas.cols - 5
      mid = canvas.cols // 2
      grid.text(2, left, "COMMAND REFERENCE", Render.accent(mode))
      keys_last = panel(grid, {4, left, mid - 2}, Section.new("KEYS", KEYS, Render::MUTED))
      flags_last = panel(grid, {4, mid, right}, Section.new("FLAGS", FLAGS, Render::MUTED))
      rows = mode == "HYDE" ? HYDE : JEKYLL
      panel(grid, {Math.max(keys_last, flags_last) + 2, left, right}, Section.new(mode, rows, Render.accent(mode)))
      grid
    end

    # One titled block of the reference: its header label, its rows, its accent.
    private record Section, label : String, rows : Array(Tuple(String, String)), accent : Render::RGB

    # Draws *section* at *geom* ({top, left, right}); returns the last row drawn.
    private def panel(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), section : Section) : Int32
      top, left, right = geom
      header(grid, geom, section.label, section.accent)
      keyw = section.rows.max_of { |(key, _)| key.size }
      rail = Render.dim(section.accent, 0.55)
      section.rows.each_with_index do |(key, desc), index|
        row = top + 1 + index
        grid.put(row, left + 1, index == section.rows.size - 1 ? '┗' : '┣', rail)
        grid.put(row, left + 2, '━', rail)
        grid.put(row, left + 3, '◈', section.accent)
        grid.text(row, left + 5, key, Render::TEXT)
        desc_col = left + 6 + keyw
        grid.text(row, desc_col, Text.clip(desc, right - desc_col + 1), Render::MUTED)
      end
      top + section.rows.size
    end

    # The heavy section header: ┏━┫ LABEL ┣━━…, matching the cockpit's dividers.
    private def header(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), label : String, accent : Render::RGB) : Nil
      top, left, right = geom
      line = Render.dim(accent, 0.55)
      grid.put(top, left, '┏', line)
      grid.put(top, left + 1, '━', line)
      grid.put(top, left + 2, '┫', line)
      grid.text(top, left + 4, label, accent)
      grid.put(top, left + 5 + label.size, '┣', line)
      (left + 6 + label.size..right).each { |col| grid.put(top, col, '━', Render.dim(accent, 0.3)) }
    end
  end
end
