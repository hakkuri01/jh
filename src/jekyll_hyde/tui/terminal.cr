require "io/console"
require "../platform/darwin"

# The terminal device.
module JekyllHyde::Tui
  # Puts the terminal into full-screen raw mode and always puts it back: on a
  # normal return, on an exception, and on the quit signals the program traps.
  # The main screen and the cursor are restored however the run ends.
  class Terminal
    # Alternate screen on, cursor hidden.
    ENTER = "\e[?1049h\e[?25l"
    # Cursor shown, main screen back, styles reset.
    LEAVE = "\e[?25h\e[?1049l\e[0m"
    # The size to assume when the terminal cannot report one.
    FALLBACK = {80, 24}

    getter input : IO::FileDescriptor
    getter output : IO

    def initialize(@input : IO::FileDescriptor = STDIN, @output : IO = STDOUT)
    end

    # Whether both ends are terminals, so the full-screen UI can run.
    def interactive? : Bool
      @input.tty? && (output = @output).is_a?(IO::FileDescriptor) && output.tty?
    end

    # Runs the block in raw mode on the alternate screen, restoring the terminal
    # however the block ends. *setup* is written just after entering (the opener
    # uploads its image there) and *teardown* just before leaving.
    def open(setup : String = "", teardown : String = "", &) : Nil
      @output << ENTER << setup
      @output.flush
      @input.raw { yield }
    ensure
      @output << teardown << LEAVE
      @output.flush
    end

    # The terminal size as {columns, rows}.
    def size : {Int32, Int32}
      Platform.terminal_size(@input) || FALLBACK
    end
  end
end
