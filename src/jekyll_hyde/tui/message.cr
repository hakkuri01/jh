# The messages that drive the Elm-architecture runtime. Something happens (a key,
# a resize, an animation tick, or a quit), a message carries it to the model, and
# the model returns a new model and an optional command. Mouse and paste land
# with the interactive shell, which is the first thing that needs them.
module JekyllHyde::Tui
  # Something that happened.
  abstract struct Msg
  end

  # A key press, named like `a`, `enter`, `esc`, `tab`, `up`, `ctrl+c`, or
  # `alt+x`. A printable key is its own character.
  struct KeyMsg < Msg
    getter key : String

    def initialize(@key : String)
    end
  end

  # The terminal changed size.
  struct ResizeMsg < Msg
    getter width : Int32
    getter height : Int32

    def initialize(@width : Int32, @height : Int32)
    end
  end

  # A frame of animation came due, carrying the monotonic clock reading at the
  # moment it fired, so the model advances on elapsed time rather than tick count.
  struct TickMsg < Msg
    getter at : Time::Instant

    def initialize(@at : Time::Instant)
    end
  end

  # Ends the program.
  struct QuitMsg < Msg
  end
end
