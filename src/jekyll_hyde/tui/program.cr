require "./decoder"
require "./screen"
require "./terminal"
require "./model"

# The program loop.
module JekyllHyde::Tui
  # Runs a model on a terminal: input, resize, and command results arrive on one
  # channel; each message updates the model, and the screen redraws what changed.
  # Ctrl-C always quits, so the user can leave whatever the model does, and so
  # does the end of input, so a program whose terminal is gone ends.
  class Program
    # How long to wait for the rest of an escape sequence before taking a lone
    # ESC as the escape key.
    ESCAPE_DELAY = 30.milliseconds

    @events = Channel(Msg).new(64)

    def initialize(@model : Model, @terminal : Terminal)
    end

    # Runs until the model quits, then restores the terminal. *setup* and
    # *teardown* are written on entering and leaving (see `Terminal#open`).
    def run(setup : String = "", teardown : String = "") : Nil
      @terminal.open(setup, teardown) do
        trap_signals
        spawn { read_input }
        screen = Screen.new(@terminal.output)
        width, height = @terminal.size
        @model, command = @model.update(ResizeMsg.new(width, height))
        dispatch(command)
        dispatch(@model.init)
        loop do
          screen.draw(@model.view(width, height))
          msg = @events.receive
          break if msg.is_a?(QuitMsg) || (msg.is_a?(KeyMsg) && msg.key == "ctrl+c")
          width, height = msg.width, msg.height if msg.is_a?(ResizeMsg)
          @model, command = @model.update(msg)
          dispatch(command)
        end
      end
    ensure
      {Signal::WINCH, Signal::INT, Signal::TERM, Signal::HUP}.each(&.reset)
    end

    # Runs *command* on its own fiber; the message it returns comes back on the
    # event channel.
    private def dispatch(command : Cmd?) : Nil
      return unless command
      spawn { @events.send(command.call) }
    end

    private def trap_signals : Nil
      Signal::WINCH.trap do
        width, height = @terminal.size
        @events.send(ResizeMsg.new(width, height))
      end
      {Signal::INT, Signal::TERM, Signal::HUP}.each(&.trap { @events.send(QuitMsg.new) })
    end

    private def read_input : Nil
      decoder = Decoder.new
      buffer = Bytes.new(4096)
      input = @terminal.input
      loop do
        input.read_timeout = decoder.pending? ? ESCAPE_DELAY : nil
        count = begin
          input.read(buffer)
        rescue IO::TimeoutError
          decoder.flush.each { |message| @events.send(message) }
          next
        end
        break if count == 0
        decoder.feed(buffer[0, count]).each { |message| @events.send(message) }
      end
      @events.send(QuitMsg.new)
    rescue IO::Error
      @events.send(QuitMsg.new)
    end
  end
end
