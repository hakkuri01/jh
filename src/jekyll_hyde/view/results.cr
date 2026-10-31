require "../render/grid"
require "../core/sanitize"
require "../core/response"
require "./hud"
require "./scene"
require "./text"

# The live results view a running scan draws into.
module JekyllHyde::View
  # The top cluster carries the scan's identity as branch nodes off the left rail
  # (the target, the live result count, and a sweeping activity pulse), and the
  # dashboard below is a node-tree of kept hits hanging off a `┏━┫ RESULTS ┣`
  # spine: a status node per row, the code, aligned size/words/lines, and the
  # path (accented when it is a directory the recursion will descend). A footer
  # carries warnings. A first pass on the look; it is iterated in the terminal.
  # Every path is sanitized here, the one boundary where a server-derived path
  # reaches the screen. A pure renderer; the App owns the session and hands a
  # snapshot.
  module Results
    extend self

    SCAN_KEYS = "↑↓ scroll · p pause · q back"
    # Glance-colors by status class: found green, redirect blue, server-error red.
    FOUND    = {120, 220, 140}
    REDIRECT = {120, 180, 240}
    # The top-cluster branch rows (off the left rail) and where their label sits.
    TOP_TARGET   = 2
    TOP_RESULTS  = 3
    TOP_PULSE    = 4
    BRANCH_LABEL = 4
    # The activity pulse: where its rail starts, its cell count, the half-width of
    # the moving glow, and its sweeps per second.
    PULSE_BASE  = BRANCH_LABEL + 9
    PULSE_CELLS =  14
    PULSE_WIDTH = 3.5
    PULSE_SPEED = 0.9
    # The dashboard sits below the top-cluster branch lines, spaced off them.
    PANEL_TOP = 6
    # Row columns relative to the panel's left edge: the tree limb and node, then
    # the right-aligned metric fields, then the path.
    NODE      =  2
    CODE_END  =  6
    SIZE_END  = 15
    WORDS_END = 22
    LINES_END = 29
    PATH      = 32
    # When, in seconds, the "slow" and "stalled" footer messages kick in.
    SLOW_AFTER    = 20.0
    STALLED_AFTER = 45.0

    # The live, changing side of a scan: whether it still runs, a failure line,
    # elapsed seconds, and the request and error tallies read off the engine.
    record Progress,
      running : Bool,
      error : String?,
      elapsed : Float64,
      requests : Int32,
      errors : Int32,
      paused : Bool = false,
      warning : String? = nil

    # The snapshot the App hands in each frame. *scroll* is how many rows the
    # newest-first dashboard has scrolled back from the newest hit (0 follows the
    # newest), so a long run can be read without losing its head or tail.
    record State,
      mode : String,
      target : String,
      hits : Array(Core::Response),
      progress : Progress,
      scroll : Int32 = 0

    # The per-row drawing context: the panel span, the target to strip, and the
    # accent for directory rows. Kept in one record to stay within the arg limit.
    record Columns,
      left : Int32,
      right : Int32,
      target : String,
      accent : Render::RGB

    def frame(canvas : Scene::Canvas, state : State) : Render::Grid
      # The status light is suppressed in the bottom cluster; the top-cluster
      # pulse carries scan status instead.
      readout = Hud::Readout.new("SCAN", true, "", false, SCAN_KEYS)
      grid = Hud.build(canvas.cols, canvas.rows, state.mode, readout)
      top_cluster(grid, canvas, state)
      panel(grid, canvas, state)
      grid
    end

    # How many result rows the dashboard shows at a terminal *height*: the frame
    # less the top cluster, divider, and column header above, and the footer and
    # margin below. The App clamps the scroll to this; the panel draws this many.
    def capacity(height : Int32) : Int32
      Math.max(0, height - (PANEL_TOP + 6))
    end

    # The scan identity hung off the top-left rail: the target, the live result
    # count, and the activity pulse, each a `┠─◈` branch node.
    private def top_cluster(grid : Render::Grid, canvas : Scene::Canvas, state : State) : Nil
      accent = Render.accent(state.mode)
      branch(grid, TOP_TARGET, accent)
      grid.text(TOP_TARGET, BRANCH_LABEL, Text.clip(Core.sanitize(state.target), canvas.cols // 2), Render::TEXT)
      branch(grid, TOP_RESULTS, accent)
      grid.text(TOP_RESULTS, BRANCH_LABEL, "#{state.hits.size} results", accent)
      branch(grid, TOP_PULSE, accent)
      activity(grid, state.progress, accent)
    end

    private def branch(grid : Render::Grid, row : Int32, accent : Render::RGB) : Nil
      grid.branch(row, 0, tee: '┠', dir: 1, color: accent)
    end

    # The pulse while running, a steady rail when finished, halted, or paused.
    private def activity(grid : Render::Grid, prog : Progress, accent : Render::RGB) : Nil
      if prog.error
        static_rail(grid, "HALTED", Render::HYDE, 0.5)
      elsif prog.paused
        static_rail(grid, "PAUSED", accent, 0.5)
      elsif prog.running
        pulse(grid, accent, prog.elapsed)
      else
        static_rail(grid, "COMPLETE", accent, 0.6)
      end
    end

    # A glowing blob of gradient ▰ cells sweeping left and right across a ▱ rail,
    # placed by elapsed time so it moves at a steady rate regardless of hits.
    private def pulse(grid : Render::Grid, accent : Render::RGB, elapsed : Float64) : Nil
      grid.text(TOP_PULSE, BRANCH_LABEL, "SCANNING", accent)
      phase = (elapsed * PULSE_SPEED) % 2.0
      center = (phase < 1.0 ? phase : 2.0 - phase) * (PULSE_CELLS - 1)
      PULSE_CELLS.times do |i|
        intensity = (1.0 - (i - center).abs / PULSE_WIDTH).clamp(0.0, 1.0)
        lit = intensity > 0.05
        color = lit ? Render.lerp(Render.dim(accent, 0.3), accent, intensity) : Render.dim(accent, 0.3)
        grid.put(TOP_PULSE, PULSE_BASE + i, lit ? '▰' : '▱', color)
      end
    end

    private def static_rail(grid : Render::Grid, label : String, color : Render::RGB, level : Float64) : Nil
      grid.text(TOP_PULSE, BRANCH_LABEL, label, color)
      PULSE_CELLS.times { |i| grid.put(TOP_PULSE, PULSE_BASE + i, '▰', Render.dim(color, level)) }
    end

    private def panel(grid : Render::Grid, canvas : Scene::Canvas, state : State) : Nil
      left = 4
      right = canvas.cols - 5
      top = PANEL_TOP
      accent = Render.accent(state.mode)
      if error = state.progress.error
        grid.text(top, left, Text.clip(Core.sanitize("error: #{error}"), right - left + 1), Render::HYDE)
        return
      end
      cap = capacity(canvas.rows)
      rows_top = top + 2
      Text.section_rail(grid, {top, left, right}, "RESULTS", accent)
      overflow(grid, top, right, state, cap: cap)
      column_header(grid, top + 1, left, accent)
      rows(grid, {rows_top, rows_top + cap - 1}, Columns.new(left, right, state.target, accent), state)
      footer(grid, {rows_top + cap, left, right}, state)
    end

    # A right-aligned position readout on the section rail when the run is taller
    # than the dashboard, so a long scan is visibly scrollable rather than silently
    # clipped: the newest-first rank range on screen, out of the total.
    private def overflow(grid : Render::Grid, row : Int32, right : Int32, state : State, *, cap : Int32) : Nil
      total = state.hits.size
      return if cap <= 0 || total <= cap
      offset = state.scroll.clamp(0, total - cap)
      grid.rtext(row, right, " #{offset + 1}-#{offset + cap} of #{total} ", Render::MUTED)
    end

    # The column labels, with the spine `┃` continuing the tree down to the rows.
    private def column_header(grid : Render::Grid, row : Int32, left : Int32, accent : Render::RGB) : Nil
      grid.put(row, left, '┃', Render.dim(accent, 0.55))
      grid.rtext(row, left + CODE_END, "CODE", Render::MUTED)
      grid.rtext(row, left + SIZE_END, "SIZE", Render::MUTED)
      grid.rtext(row, left + WORDS_END, "WORDS", Render::MUTED)
      grid.rtext(row, left + LINES_END, "LINES", Render::MUTED)
      grid.text(row, left + PATH, "PATH", Render::MUTED)
    end

    # The window of hits that fits, newest-first, scrolled back by *scroll* rows
    # and clamped so it never runs off either end; each row is a node on the
    # spine (`┣━◈`, the last `┗━◈`).
    private def rows(grid : Render::Grid, vert : Tuple(Int32, Int32), cols : Columns, state : State) : Nil
      top, bottom = vert
      hits, scroll = state.hits, state.scroll
      limit = bottom - top + 1
      return if limit <= 0 || hits.empty?
      offset = scroll.clamp(0, Math.max(0, hits.size - limit))
      newest = hits.size - 1 - offset
      count = Math.min(limit, newest + 1)
      rail = Render.dim(cols.accent, 0.55)
      count.times do |i|
        at = top + i
        grid.put(at, cols.left, i == count - 1 ? '┗' : '┣', rail)
        grid.put(at, cols.left + 1, '━', rail)
        row(grid, at, cols, hits[newest - i])
      end
    end

    private def row(grid : Render::Grid, at : Int32, cols : Columns, hit : Core::Response) : Nil
      color = status_color(hit.status)
      grid.put(at, cols.left + NODE, '◈', color)
      grid.rtext(at, cols.left + CODE_END, hit.status.to_s, color)
      grid.rtext(at, cols.left + SIZE_END, hit.size.to_s, Render::TEXT)
      grid.rtext(at, cols.left + WORDS_END, hit.words.to_s, Render::MUTED)
      grid.rtext(at, cols.left + LINES_END, hit.lines.to_s, Render::MUTED)
      width = cols.right - (cols.left + PATH) + 1
      path = Text.clip(Core.sanitize(path_of(hit, cols.target), width + 1), width)
      grid.text(at, cols.left + PATH, path, directoryish?(hit) ? cols.accent : Render::TEXT)
    end

    # The status footer: warnings only while running (completion and the count
    # live in the top cluster now), so a quiet, healthy scan shows nothing here.
    private def footer(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), state : State) : Nil
      row, left, right = geom
      note = message(state.progress, state.hits.size)
      return unless note
      grid.text(row, left, Text.clip(note[0], right - left + 1), note[1])
    end

    # The contextual warning line: a non-fatal notice (crawl cap hit, export
    # failed) first, then the running-scan health hints.
    private def message(prog : Progress, hits : Int32) : {String, Render::RGB}?
      if note = prog.warning
        return {"⚠ #{note}", Render::HYDE}
      end
      return nil unless prog.running
      if prog.requests > 0 && prog.errors == prog.requests
        {"⚠ target not responding; every request has errored", Render::HYDE}
      elsif prog.requests > 20 && prog.errors * 2 > prog.requests
        {"⚠ erroring out: #{prog.errors}/#{prog.requests} requests failed", Render::HYDE}
      elsif prog.elapsed > SLOW_AFTER && hits == 0
        {"… no results yet; the wordlist may not match, or responses were filtered", Render::MUTED}
      elsif prog.elapsed > STALLED_AFTER
        {"… taking longer than usual", Render::MUTED}
      end
    end

    # The path shown for a hit: the target stripped off at a path boundary, so a
    # row reads `/admin`, an exact hit shows `/`, and a target that only prefixes a
    # longer path (`/app` vs `/apples`) shows the full URL, not `les`.
    # ponytail: this runs per visible row per frame, so it is one tail slice over
    # a URL bounded by Extractor::MAX_LINK_BYTES (8 KiB), inside a window bounded
    # by the terminal height, never over the result set. Measured flat in URL
    # length (0.10 ms/frame at 34 rows for 40-char and 8 KiB URLs alike, against a
    # 33 ms budget), since the caller's sanitize is already capped to the column
    # width. Precompute off the frame only if that headroom disappears.
    private def path_of(hit : Core::Response, target : String) : String
      return hit.url unless hit.url.starts_with?(target)
      rel = hit.url[target.size..]
      return hit.url unless rel.empty? || rel.starts_with?("/")
      rel.empty? ? "/" : rel
    end

    # Whether a hit is a directory the Hyde walk will descend: a redirect with a
    # Location, or a path already ending in a slash. Accented as the frontier.
    private def directoryish?(hit : Core::Response) : Bool
      return true if (300..399).includes?(hit.status) && !hit.location.nil?
      hit.url.ends_with?("/")
    end

    private def status_color(status : Int32) : Render::RGB
      case status
      when 200..299 then FOUND
      when 300..399 then REDIRECT
      when 500..599 then Render::HYDE
      else               Render::MUTED
      end
    end
  end
end
