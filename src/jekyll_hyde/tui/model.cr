require "./message"
require "../render/grid"

# The Elm-architecture contract the program drives.
module JekyllHyde::Tui
  # Work to do away from the input loop; it runs on its own fiber and the message
  # it returns goes back to the model. Animation is the only use for now: a tick
  # command sleeps a frame, then reports the clock.
  alias Cmd = Proc(Msg)

  # A command that ends the program, returned by the model on a quit key. The
  # cast widens the concrete QuitMsg to the Msg union the Cmd must return.
  QUIT = Cmd.new { QuitMsg.new.as(Msg) }

  # A command that waits *span*, then reports a `TickMsg`; a model animates by
  # answering each tick with the next one until the animation settles.
  def self.tick(span : Time::Span) : Cmd
    Cmd.new do
      sleep span
      # Widen the concrete TickMsg to the Msg union the Cmd block must return.
      TickMsg.new(Time.instant).as(Msg)
    end
  end

  # A screen: its state, how a message changes it, and how it draws itself as a
  # cell grid for the current size.
  module Model
    # The command to run when the program starts, or nil.
    abstract def init : Cmd?

    # The model after *msg*, with the command to run next, if any.
    abstract def update(msg : Msg) : {Model, Cmd?}

    # The frame to draw at *width* by *height*.
    abstract def view(width : Int32, height : Int32) : Render::Grid
  end
end
