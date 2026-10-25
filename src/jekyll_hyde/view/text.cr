# Shared text helpers for the view layer.
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
  end
end
