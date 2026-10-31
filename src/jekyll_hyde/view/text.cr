# Shared text helpers for the view layer.
require "../render/grid"

module JekyllHyde::View
  module Text
    extend self

    # *text* cut to *width* cells, a trailing ellipsis marking a cut.
    def clip(text : String, width : Int32) : String
      return "" if width <= 0
      return text if text.size <= width
      return text[0, width] if width < 2
      "#{text[0, width - 1]}…"
    end

    # A section rail `┏━┫ LABEL ┣━━…` across *geom* ({row, left, right}), the spine
    # a content panel hangs its node rows from. Shared by the results and finder
    # dashboards so the one rail is not two copies that drift apart.
    def section_rail(grid : Render::Grid, geom : Tuple(Int32, Int32, Int32), label : String, accent : Render::RGB) : Nil
      row, left, right = geom
      rail = Render.dim(accent, 0.55)
      grid.put(row, left, '┏', rail)
      grid.put(row, left + 1, '━', rail)
      grid.put(row, left + 2, '┫', rail)
      grid.text(row, left + 4, label, accent)
      close = left + 5 + label.size
      grid.put(row, close, '┣', rail)
      (close + 1..right).each { |col| grid.put(row, col, '━', Render.dim(accent, 0.3)) }
    end
  end
end
