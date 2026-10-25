require "../render/grid"
require "../render/logo"
require "./hud"
require "./scene"

# The composition cockpit.
module JekyllHyde::View
  # The scan-composition panel: a decorated double-line frame, titleless (the
  # HUD already names the mode), holding the logo and the fields as a heavy
  # node-tree of input wells. A field's node is a filled ◈ when mandatory and a
  # hollow ◇ when optional, so the user can see what Enter still needs; the
  # numeric engine fields show a notch meter. Recursion is not a field: Hyde
  # recurses natively and Jekyll does not recurse, so
  # the recursion-depth field shows only in Hyde. The live `jh …` command wraps
  # at the foot, the frame growing rather than letting it breach the border. The
  # App owns the values and focus; this is a pure renderer.
  module Shell
    extend self

    # The Jekyll injection keyword.
    KEYWORD = "FUZZ"
    # The key cheatsheets docked into the HUD, by mode.
    NORMAL_KEYS = "j/k move · i edit · / find · tab mode · enter run · h help · q quit"
    INSERT_KEYS = "type · enter run · esc normal"
    # The panel's widest width in cells, and the numeric meter's notch count.
    CARD_MAX = 74
    NOTCHES  = 12

    # How a field takes its value.
    enum Kind
      Text
      Number
    end

    # One composable scan option. step is the value a Number field's meter adds
    # per filled notch; group is the section it sits under; hyde_only keeps the
    # recursion-depth field out of Jekyll, and jekyll_only keeps the status
    # matcher and filter out of Hyde (which has no matcher grammar). The two
    # modes' field lists diverge at both ends because of these.
    record Field,
      label : String,
      flag : String,
      kind : Kind,
      default : String,
      hint : String,
      step : Int32,
      required : Bool,
      group : String,
      hyde_only : Bool,
      jekyll_only : Bool

    # Every field, in order. Target and wordlist are mandatory; the rest are
    # optional. The flags are the exact CLI flags, so the composed `jh …` line is
    # a runnable command (multi-character flags are double-dashed, Crystal's
    # option style).
    ALL = [
      Field.new("URL", "-u", Kind::Text, "", "https://target", 0, true, "TARGET", false, false),
      Field.new("WORDLIST", "-w", Kind::Text, "", "wordlist.txt", 0, true, "TARGET", false, false),
      Field.new("EXTENSIONS", "-e", Kind::Text, "", "php,html,txt", 0, false, "TARGET", false, false),
      Field.new("THREADS", "-t", Kind::Number, "40", "40", 10, false, "ENGINE", false, false),
      Field.new("DEPTH", "-d", Kind::Number, "4", "4", 1, false, "ENGINE", true, false),
      Field.new("MATCH", "--mc", Kind::Text, "", "200,301,403", 0, false, "MATCHING", false, true),
      Field.new("FILTER", "--fc", Kind::Text, "", "404,500", 0, false, "MATCHING", false, true),
    ]

    # The widest label, so the wells line up.
    LABELW = ALL.max_of(&.label.size)

    # The editable state the App owns.
    record State, mode : String, field : Int32, editing : Bool, values : Array(String), cursor : Int32

    # The laid-out row of every panel element for a given terminal height.
    record Plan,
      top : Int32,
      height : Int32,
      logo_top : Int32,
      fields : Array(Int32),
      dividers : Array(Tuple(Int32, String)),
      command : Int32

    # The fields shown in *mode*: Hyde adds recursion depth and drops the status
    # matcher/filter, Jekyll does the reverse.
    def fields(mode : String) : Array(Field)
      ALL.reject { |field| mode == "HYDE" ? field.jekyll_only : field.hyde_only }
    end

    # The value of the field carrying *flag* in *state*, or "" when that flag has
    # no field in the current mode. Reads are by flag, not index, because the two
    # modes' field lists differ at both ends.
    def value(state : State, flag : String) : String
      fs = fields(state.mode)
      if index = fs.index { |field| field.flag == flag }
        state.values[index]
      else
        ""
      end
    end

    # A mode's starting values (the engine swap resets to these).
    def defaults(mode : String) : Array(String)
      fields(mode).map(&.default)
    end

    # Whether the mandatory fields are set: a target and a wordlist, and in
    # Jekyll a FUZZ keyword in the target.
    def ready?(state : State) : Bool
      return false if state.values[0].empty? || state.values[1].empty?
      state.mode != "JEKYLL" || state.values[0].includes?(KEYWORD)
    end

    # The composition frame: the HUD chrome with the vim readout, and the panel.
    def frame(canvas : Scene::Canvas, state : State) : Render::Grid
      ready = ready?(state)
      keys = state.editing ? INSERT_KEYS : NORMAL_KEYS
      readout = Hud::Readout.new(state.editing ? "INSERT" : "NORMAL", state.editing, ready ? "◉ READY" : "○ STANDBY", ready, keys)
      grid = Hud.build(canvas.cols, canvas.rows, state.mode, readout)
      card(grid, canvas, state)
      grid
    end

    # The panel: the decorated box, the logo inside, the node-tree of fields
    # (grouped when tall), and the wrapped command, centered above the cluster.
    private def card(grid : Render::Grid, canvas : Scene::Canvas, state : State) : Nil
      fs = fields(state.mode)
      card_w = Math.min(canvas.cols - 8, CARD_MAX)
      left = (canvas.cols - card_w) // 2
      lines = wrap_command(command_segments(state), Math.max(card_w - 8, 1))
      pl = plan(canvas.rows, fs, lines.size)
      accent = Render.accent(state.mode)
      box(grid, {pl.top, left, card_w, pl.height}, accent)
      place_logo(grid, canvas, {pl.logo_top, left, card_w})
      pl.dividers.each { |entry| divider(grid, {entry[0], left, card_w}, entry[1], accent) }
      tree = !pl.dividers.empty?
      pl.fields.each_with_index do |row, index|
        field = fs[index]
        last = index == fs.size - 1 || fs[index + 1].group != field.group
        field_row(grid, state, index, RowCtx.new(row, left, card_w, tree, field, last))
      end
      draw_command(grid, state.mode, lines, {pl.command, left + 3})
    end

    # Lays out the panel: full grouping and breathing gaps when tall, the compact
    # logo-plus-fields core when short, always sized to clear the bottom cluster.
    private def plan(rows_total : Int32, fs : Array(Field), cmd : Int32) : Plan
      budget = rows_total - 8
      base = Scene::LOGO_ROWS + fs.size + 2 + cmd
      groups = fs.map(&.group).uniq!.size
      sections = budget - base >= groups
      height = base + (sections ? groups : 0)
      gaps = budget - height >= 2
      height += 2 if gaps
      top = 2 + Math.max((budget - height) // 2, 0)
      cursor = top + 1
      logo_top = cursor
      cursor += Scene::LOGO_ROWS + (gaps ? 1 : 0)
      dividers = [] of Tuple(Int32, String)
      rows = [] of Int32
      prev = ""
      fs.each do |field|
        if sections && field.group != prev
          dividers << {cursor, field.group}
          cursor += 1
        end
        prev = field.group
        rows << cursor
        cursor += 1
      end
      Plan.new(top, height, logo_top, rows, dividers, cursor + (gaps ? 1 : 0))
    end

    # The decorated double-line frame: edges bright at the corners and dim in the
    # middle (the HUD's energized-at-the-nodes look), diagonal ▰▰▱ signal caps at
    # opposite corners, and two ◈ rivets down each side wall.
    private def box(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32, Int32), accent : Render::RGB) : Nil
      top, left, width, height = geom
      right, bottom = left + width - 1, top + height - 1
      dim = Render.dim(accent, 0.45)
      (left..right).each do |col|
        near = Math.min(col - left, right - col) < 6
        grid.put(top, col, '═', near ? accent : dim)
        grid.put(bottom, col, '═', near ? accent : dim)
      end
      (top + 1...bottom).each do |row|
        near = Math.min(row - top, bottom - row) < 3
        grid.put(row, left, '║', near ? accent : dim)
        grid.put(row, right, '║', near ? accent : dim)
      end
      grid.put(top, left, '╔', accent)
      grid.put(top, right, '╗', accent)
      grid.put(bottom, left, '╚', accent)
      grid.put(bottom, right, '╝', accent)
      {'▰', '▰', '▱'}.each_with_index { |glyph, offset| grid.put(top, left + 2 + offset, glyph, accent) }
      {'▱', '▰', '▰'}.each_with_index { |glyph, offset| grid.put(bottom, right - 4 + offset, glyph, accent) }
      [height // 3, height * 2 // 3].each do |rivet|
        grid.put(top + rivet, left, '◈', accent)
        grid.put(top + rivet, right, '◈', accent)
      end
    end

    # A heavy section header rooted at the field tree's spine: ┏━┫ LABEL ┣━━…,
    # the ┏ connecting down to the ┣/┗ of the fields below. *geom* is
    # {row, left, width}.
    private def divider(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), label : String, accent : Render::RGB) : Nil
      row, left, width = geom
      line = Render.dim(accent, 0.55)
      spine = left + 4
      grid.put(row, spine, '┏', line)
      grid.put(row, spine + 1, '━', line)
      grid.put(row, spine + 2, '┫', line)
      grid.text(row, spine + 4, label, accent)
      grid.put(row, spine + 5 + label.size, '┣', line)
      (spine + 6 + label.size..left + width - 4).each { |col| grid.put(row, col, '━', Render.dim(accent, 0.3)) }
    end

    # The logo inside the panel, centered, when the terminal shows images.
    private def place_logo(grid : Render::Grid, canvas : Scene::Canvas, geom : Tuple(Int32, Int32, Int32)) : Nil
      return unless canvas.images
      top, left, card_w = geom
      width = Render::Logo.cell_width(Scene::LOGO_ROWS)
      grid.placement = Render::Placement.new(Scene::LOGO_ID, top, left + (card_w - width) // 2, width, Scene::LOGO_ROWS)
    end

    # One field drawn, row-wide, by the RowCtx: a heavy tree limb (┣/┗) when
    # grouped, a ◈/◇ node for mandatory/optional, the label, a side-ticked value
    # well washed to mark focus, and a bracketed flag badge.
    private def field_row(grid : Render::Grid, state : State, index : Int32, ctx : RowCtx) : Nil
      field, row, left, width = ctx.field, ctx.row, ctx.left, ctx.width
      accent = Render.accent(state.mode)
      focused = state.field == index
      editing = focused && state.editing
      well_left = left + 9 + LABELW
      content_right = left + width - 4
      badge = "[#{field.flag.lstrip('-')}]"
      well_right = content_right - badge.size - 1
      limb(grid, {row, left + 4}, ctx.last, Render.dim(accent, 0.55)) if ctx.tree
      grid.put(row, left + 6, field.required ? '◈' : '◇', node_color(field, focused, accent))
      grid.text(row, left + 8, field.label.ljust(LABELW), label_color(field, focused, accent))
      grid.put(row, well_left, '▏', focused ? accent : Render.dim(accent, 0.5))
      grid.put(row, well_right, '▕', focused ? accent : Render.dim(accent, 0.5))
      caret = well_body(grid, {row, well_left + 2, well_right - 1}, field, {state.values[index], editing, state.mode, state.cursor})
      grid.text(row, content_right - badge.size + 1, badge, focused ? Render.dim(accent, 0.75) : Render::MUTED)
      grid.wash(row, left + 4, width - 7, Render.dim(accent, 0.12)) if focused
      grid.wash(row, well_left, well_right - well_left + 1, focused ? Render.dim(accent, 0.3) : Render::SURFACE)
      grid.wash(row, caret, 1, accent) if caret >= 0
    end

    # The per-field drawing context the card hands to a row.
    record RowCtx,
      row : Int32,
      left : Int32,
      width : Int32,
      tree : Bool,
      field : Field,
      last : Bool

    # A tree limb hanging off the spine: ┗━ for the last field in a group, ┣━
    # otherwise. *at* is {row, spine}.
    private def limb(grid : Render::Grid, at : Tuple(Int32, Int32), last : Bool, line : Render::RGB) : Nil
      row, spine = at
      grid.put(row, spine, last ? '┗' : '┣', line)
      grid.put(row, spine + 1, '━', line)
    end

    private def node_color(field : Field, focused : Bool, accent : Render::RGB) : Render::RGB
      return accent if focused || field.required
      Render.dim(accent, 0.45)
    end

    private def label_color(field : Field, focused : Bool, accent : Render::RGB) : Render::RGB
      return accent if focused
      field.required ? Render::TEXT : Render::MUTED
    end

    # Draws a well's value glyphs; returns the caret column while editing text,
    # or -1. *geom* is {row, first, last} of the usable interior.
    private def well_body(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), field : Field, view : Tuple(String, Bool, String, Int32)) : Int32
      row, col, last = geom
      value, editing, mode, cursor = view
      if field.kind.number?
        meter(grid, {row, col, last}, {value, field.step, mode})
        -1
      else
        text_value(grid, {row, col, last}, field, {value, editing, mode, cursor})
      end
    end

    # The text value or its dim hint, tail-truncated to the well, FUZZ in violet.
    # While editing, the field scrolls to keep the caret in view (the caret may
    # sit mid-string), and the caret column is returned; otherwise -1.
    private def text_value(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), field : Field, view : Tuple(String, Bool, String, Int32)) : Int32
      row, col, last = geom
      value, editing, mode, cursor = view
      width = last - col + 1
      if editing
        win = Math.max(width - 1, 1)
        start = value.size <= win ? 0 : (cursor - win // 2).clamp(0, value.size - win)
        shown = value[start, win]
        grid.text(row, col, shown, Render::TEXT)
        highlight_fuzz(grid, row, col, shown) if mode == "JEKYLL" && field.flag == "-u"
        col + (cursor - start)
      else
        dim = value.empty?
        shown = dim ? hint(field, mode) : value
        shown = "…" + shown[Math.max(shown.size - width + 1, 0)..] if shown.size > width && width > 1
        grid.text(row, col, shown, dim ? Render::MUTED : Render::TEXT)
        highlight_fuzz(grid, row, col, shown) if mode == "JEKYLL" && field.flag == "-u"
        -1
      end
    end

    # A notch meter: the number, then one ▰ (dim-to-accent gradient) per *step*
    # of value up to NOTCHES notches, the rest ▱; a larger value stays full.
    # *view* is {value, step, mode}.
    private def meter(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), view : Tuple(String, Int32, String)) : Nil
      row, col, last = geom
      value, step, mode = view
      accent = Render.accent(mode)
      grid.text(row, col, value, Render::TEXT)
      bar = col + 4
      cells = Math.min(last - bar + 1, NOTCHES)
      return if cells <= 0
      filled = step <= 0 ? 0 : Math.min((value.to_i? || 0) // step, cells)
      cells.times do |offset|
        lit = offset < filled
        color = lit ? Render.lerp(Render.dim(accent, 0.5), accent, offset / cells.to_f) : Render.dim(accent, 0.35)
        grid.put(row, bar + offset, lit ? '▰' : '▱', color)
      end
    end

    # jh, the mode flag, then each field that carries data; a flag appears only
    # once its field holds a value, so the command builds up as the form fills.
    private def command_segments(state : State) : Array(Tuple(String, Render::RGB))
      accent = Render.accent(state.mode)
      jekyll = state.mode == "JEKYLL"
      segments = [{"jh", Render::MUTED}, {jekyll ? "--jekyll" : "--hyde", accent}]
      fields(state.mode).each_with_index do |field, index|
        value = state.values[index]
        next if value.empty?
        segments << {field.flag, Render::MUTED}
        segments << {value, Render::TEXT}
      end
      segments
    end

    # Flattens the command to styled cells, then wraps to lines of *width*.
    private def wrap_command(segments : Array(Tuple(String, Render::RGB)), width : Int32) : Array(Array(Tuple(Char, Render::RGB)))
      cells = [] of Tuple(Char, Render::RGB)
      segments.each_with_index do |segment, index|
        cells << {' ', Render::MUTED} if index > 0
        segment[0].each_char { |glyph| cells << {glyph, segment[1]} }
      end
      wrap_cells(cells, Math.max(width, 1))
    end

    # Greedy word-wrap on styled cells: break at the last space in reach, else
    # hard-break an over-long token so nothing breaches the panel.
    private def wrap_cells(cells : Array(Tuple(Char, Render::RGB)), width : Int32) : Array(Array(Tuple(Char, Render::RGB)))
      lines = [] of Array(Tuple(Char, Render::RGB))
      at = 0
      while at < cells.size
        stop = Math.min(at + width, cells.size)
        brk = -1
        (at...stop).each { |index| brk = index if cells[index][0] == ' ' }
        if stop < cells.size && brk > at
          lines << cells[at...brk]
          at = brk + 1
        else
          lines << cells[at...stop]
          at = stop
        end
      end
      lines.empty? ? [[] of Tuple(Char, Render::RGB)] : lines
    end

    # The wrapped command at the panel foot, a › prompt on the first line.
    # *geom* is {row, left}.
    private def draw_command(grid : Render::Grid, mode : String, lines : Array(Array(Tuple(Char, Render::RGB))), geom : Tuple(Int32, Int32)) : Nil
      row, left = geom
      accent = Render.accent(mode)
      lines.each_with_index do |cells, offset|
        grid.put(row + offset, left, offset.zero? ? '›' : ' ', accent)
        cells.each_with_index { |cell, col| grid.put(row + offset, left + 2 + col, cell[0], cell[1]) }
      end
    end

    # Recolors each FUZZ occurrence in *text* (placed from *start*) violet.
    private def highlight_fuzz(grid : Render::Grid, row : Int32, start : Int32, text : String) : Nil
      offset = 0
      while index = text.index(KEYWORD, offset)
        KEYWORD.each_char_with_index { |glyph, pos| grid.put(row, start + index + pos, glyph, Render::JEKYLL) }
        offset = index + KEYWORD.size
      end
    end

    # The dim hint for an empty field; the target carries FUZZ in Jekyll.
    private def hint(field : Field, mode : String) : String
      field.flag == "-u" && mode == "JEKYLL" ? "#{field.hint}/#{KEYWORD}" : field.hint
    end
  end
end
