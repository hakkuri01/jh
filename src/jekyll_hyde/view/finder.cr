require "../render/grid"
require "../core/sanitize"
require "../wordlist/list"
require "../jekyll/input"
require "./hud"
require "./scene"
require "./text"

# The composer's read-only wordlist finder.
module JekyllHyde::View
  # A preview overlay opened from the cockpit with `/` on a filled wordlist
  # field: it loads the list once and filters it live by substring. Every
  # printable key, `q` included, extends the filter, so Esc (or Enter) is the
  # exit, never a letter. Read-only: it never mutates the form or launches. The
  # App holds a `Session` while the overlay is open and renders its snapshot.
  module Finder
    extend self

    FINDER_KEYS = "type · ↑↓ scroll · esc/enter back"
    # The dashboard sits below the top cluster and the filter well.
    PANEL_TOP = 6
    # Row columns relative to the panel's left edge.
    NODE  = 2
    ENTRY = 4

    # The loaded list, the live query, and the scroll offset the App drives
    # through `handle`. The list is read once with the active mode's own
    # discipline, so the preview matches what the scan will request: Hyde
    # deduplicates and cleans, Jekyll keeps the file as-is. Each keystroke
    # refilters in one O(W) pass, the per-input-change cost the Big O budget
    # allows. An unreadable file is held as a one-line error, never raised.
    class Session
      enum Action
        Close
        Stay
      end

      getter query : String = ""
      getter error : String?
      getter source : String
      getter total : Int32
      getter scroll : Int32 = 0
      getter matches : Array(String)

      @mode : String
      @list : Wordlist::List

      def initialize(spec : String, @mode : String)
        path = Jekyll::Source.split(spec)[0]
        @source = Path[path].basename
        @error = nil
        @list = load(path)
        @total = @list.size
        @matches = @list.find("")
      end

      private def load(path : String) : Wordlist::List
        @mode == "HYDE" ? Wordlist::List.deduplicated({path}) : Wordlist::List.positional({path})
      rescue File::Error
        @error = "could not read #{@source}"
        Wordlist::List.new([] of String)
      end

      # Route a key: Esc/Enter close; the arrows and paging scroll (clamped with
      # *capacity*, how many rows fit); Backspace trims the filter; every other
      # printable key extends it.
      def handle(name : String, capacity : Int32) : Action
        case name
        when "esc", "enter" then return Action::Close
        when "down"         then scroll_by(1, capacity)
        when "up"           then scroll_by(-1, capacity)
        when "pgdown"       then scroll_by(capacity, capacity)
        when "pgup"         then scroll_by(-capacity, capacity)
        when "home"         then @scroll = 0
        when "end"          then @scroll = max_scroll(capacity)
        when "backspace"    then backspace
        else                     type(name)
        end
        Action::Stay
      end

      # Keep the scroll in range after a resize changes how many rows fit.
      def clamp(capacity : Int32) : Nil
        @scroll = @scroll.clamp(0, max_scroll(capacity))
      end

      def state : State
        State.new(@mode, @source, @total, @query, @matches, @scroll, @error)
      end

      private def type(name : String) : Nil
        return unless name.size == 1
        @query += name
        refilter
      end

      private def backspace : Nil
        return if @query.empty?
        @query = @query[0, @query.size - 1]
        refilter
      end

      # A changed query resets the scroll: the match set is different now.
      private def refilter : Nil
        @matches = @list.find(@query)
        @scroll = 0
      end

      private def scroll_by(delta : Int32, capacity : Int32) : Nil
        @scroll = (@scroll + delta).clamp(0, max_scroll(capacity))
      end

      private def max_scroll(capacity : Int32) : Int32
        Math.max(0, @matches.size - capacity)
      end
    end

    # The snapshot the App hands in each frame; *scroll* is how far the match
    # list has scrolled from the top.
    record State,
      mode : String,
      source : String,
      total : Int32,
      query : String,
      matches : Array(String),
      scroll : Int32,
      error : String?

    # The per-row drawing context: the panel span and the accent, in one record
    # to stay within the argument limit.
    record Columns,
      left : Int32,
      right : Int32,
      accent : Render::RGB

    # How many match rows fit at a terminal *height*: the frame less the top
    # cluster, the filter well, and the divider above, and the footer and frame
    # margin below. The App clamps its scroll to this and the panel draws exactly
    # this many, so the two never drift.
    def capacity(height : Int32) : Int32
      Math.max(0, height - (PANEL_TOP + 5))
    end

    def frame(canvas : Scene::Canvas, state : State) : Render::Grid
      readout = Hud::Readout.new("FINDER", true, "", false, FINDER_KEYS)
      grid = Hud.build(canvas.cols, canvas.rows, state.mode, readout)
      accent = Render.accent(state.mode)
      top_cluster(grid, canvas, state, accent)
      search(grid, {4, 4, canvas.cols - 5}, state, accent)
      panel(grid, canvas, state, accent)
      grid
    end

    # The source file and the live match tally, hung off the top-left rail as
    # `┠─◈` branch nodes; the source turns red and reads as the error if the list
    # could not be read. The label is sanitized on both branches, since the
    # error carries the (operator-chosen) basename.
    private def top_cluster(grid : Render::Grid, canvas : Scene::Canvas, state : State, accent : Render::RGB) : Nil
      grid.branch(2, 0, tee: '┠', dir: 1, color: accent)
      label = Core.sanitize(state.error || state.source)
      grid.text(2, 4, Text.clip(label, canvas.cols // 2), state.error ? Render::HYDE : Render::TEXT)
      grid.branch(3, 0, tee: '┠', dir: 1, color: accent)
      tally = state.matches.size == state.total ? "#{state.total} entries" : "#{state.matches.size} of #{state.total}"
      grid.text(3, 4, tally, accent)
    end

    # The filter input well: a `/` prompt, a side-ticked well washed to mark it
    # active, the query tail-truncated so the caret stays in view, and the caret
    # as an accent-washed cell at the end.
    private def search(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), state : State, accent : Render::RGB) : Nil
      row, left, right = geom
      grid.put(row, left, '/', accent)
      well_left, well_right = left + 2, right
      grid.put(row, well_left, '▏', accent)
      grid.put(row, well_right, '▕', accent)
      width = well_right - well_left - 3
      query = Core.sanitize(state.query)
      shown = query.size > width && width > 1 ? "…#{query[(query.size - width + 1)..]}" : query
      grid.text(row, well_left + 2, shown, Render::TEXT)
      grid.wash(row, well_left + 1, well_right - well_left - 1, Render.dim(accent, 0.3))
      grid.wash(row, well_left + 2 + shown.size, 1, accent)
    end

    private def panel(grid : Render::Grid, canvas : Scene::Canvas, state : State, accent : Render::RGB) : Nil
      left = 4
      right = canvas.cols - 5
      top = PANEL_TOP
      cap = capacity(canvas.rows)
      rows_top = top + 1
      divider(grid, {top, left, right}, accent)
      overflow(grid, top, right, state, cap)
      rows(grid, {rows_top, rows_top + cap - 1}, Columns.new(left, right, accent), state)
      footer(grid, {rows_top + cap, left, right}, state)
    end

    # A right-aligned position readout on the section rail when the matches run
    # taller than the panel, so a long list reads as scrollable, not clipped.
    private def overflow(grid : Render::Grid, row : Int32, right : Int32, state : State, cap : Int32) : Nil
      total = state.matches.size
      return if cap <= 0 || total <= cap
      offset = state.scroll.clamp(0, total - cap)
      grid.rtext(row, right, " #{offset + 1}-#{offset + cap} of #{total} ", Render::MUTED)
    end

    # The section rail `┏━┫ MATCHES ┣━━…`, the spine the entry nodes hang from.
    private def divider(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), accent : Render::RGB) : Nil
      row, left, right = geom
      rail = Render.dim(accent, 0.55)
      grid.put(row, left, '┏', rail)
      grid.put(row, left + 1, '━', rail)
      grid.put(row, left + 2, '┫', rail)
      grid.text(row, left + 4, "MATCHES", accent)
      grid.put(row, left + 12, '┣', rail)
      (left + 13..right).each { |col| grid.put(row, col, '━', Render.dim(accent, 0.3)) }
    end

    # The window of matches that fits, in file order, scrolled by the state's
    # offset and clamped so it never runs off either end; each a node on the
    # spine (`┣━◈`, the last `┗━◈`). Each entry is sanitized to at most the
    # visible width here, the one boundary where a file-supplied line reaches the
    # screen, so a pathologically long line costs O(width), not O(line).
    private def rows(grid : Render::Grid, vert : Tuple(Int32, Int32), cols : Columns, state : State) : Nil
      top, bottom = vert
      limit = bottom - top + 1
      return if limit <= 0 || state.matches.empty?
      offset = state.scroll.clamp(0, Math.max(0, state.matches.size - limit))
      count = Math.min(limit, state.matches.size - offset)
      rail = Render.dim(cols.accent, 0.55)
      width = cols.right - (cols.left + ENTRY) + 1
      count.times do |i|
        at = top + i
        grid.put(at, cols.left, i == count - 1 ? '┗' : '┣', rail)
        grid.put(at, cols.left + 1, '━', rail)
        grid.put(at, cols.left + NODE, '◈', Render.dim(cols.accent, 0.8))
        entry = Text.clip(Core.sanitize(state.matches[offset + i], width + 1), width)
        grid.text(at, cols.left + ENTRY, entry, Render::TEXT)
      end
    end

    # A quiet note under the list: an empty wordlist, or a query that matches
    # nothing. Silent while matches exist (the list speaks for itself).
    private def footer(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), state : State) : Nil
      row, left, right = geom
      note = note_for(state)
      return unless note
      grid.text(row, left, Text.clip(note, right - left + 1), Render::MUTED)
    end

    private def note_for(state : State) : String?
      return nil if state.error
      return "the wordlist has no entries" if state.total == 0
      return "nothing matches \u{201c}#{Core.sanitize(state.query)}\u{201d}" if state.matches.empty?
      nil
    end
  end
end
