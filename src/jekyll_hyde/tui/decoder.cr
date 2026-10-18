require "./message"

# Terminal input decoding.
module JekyllHyde::Tui
  # Turns the bytes a terminal sends into key messages. It is a pure state
  # machine: bytes go in with `feed`, and a sequence cut short (a lone ESC, for
  # example) is resolved by `flush` once no more input arrives. Mouse and paste
  # decoding land with the shell that first needs them.
  class Decoder
    # The keys sent as `ESC [ <letter>` or `ESC O <letter>`.
    LETTER_KEYS = {'A' => "up", 'B' => "down", 'C' => "right", 'D' => "left", 'H' => "home", 'F' => "end", 'Z' => "backtab"}
    # The keys sent as `ESC [ <number> ~`.
    TILDE_KEYS = {"1" => "home", "3" => "delete", "4" => "end", "5" => "pgup", "6" => "pgdown"}

    @raw = Bytes.empty
    @buffer = ""

    # Decodes *bytes*, with whatever was left from earlier, into messages.
    def feed(bytes : Bytes) : Array(Msg)
      text, @raw = split_utf8(@raw + bytes)
      @buffer += text
      messages = [] of Msg
      until @buffer.empty?
        used = step(@buffer, messages)
        break if used == 0
        @buffer = @buffer.byte_slice(used)
      end
      messages
    end

    # Whether input is waiting for the rest of a sequence.
    def pending? : Bool
      !@buffer.empty? || !@raw.empty?
    end

    # Resolves what is waiting once no more input comes: a lone ESC is the escape
    # key, and anything else unfinished is dropped.
    def flush : Array(Msg)
      lone_escape = @buffer == "\e"
      @buffer, @raw = "", Bytes.empty
      lone_escape ? [KeyMsg.new("esc")] of Msg : [] of Msg
    end

    # Decodes one key from the start of *text* into *messages* and returns the
    # bytes used, or 0 when *text* is an unfinished sequence.
    private def step(text : String, messages : Array(Msg)) : Int32
      return escape_step(text, messages) if text[0] == '\e'
      messages << KeyMsg.new(control_name(text[0]))
      text[0].bytesize
    end

    private def escape_step(text : String, messages : Array(Msg)) : Int32
      return 0 if text.size == 1
      kind = text[1]
      return sequence_step(text, messages, kind) if kind == '[' || kind == 'O'
      if kind == '\e'
        messages << KeyMsg.new("esc")
        return 1
      end
      messages << KeyMsg.new("alt+#{control_name(kind)}")
      1 + kind.bytesize
    end

    # `ESC [` (CSI) or `ESC O` (SS3), digits and semicolons, then a final
    # character. Unknown sequences are dropped whole.
    private def sequence_step(text : String, messages : Array(Msg), kind : Char) : Int32
      index = parameters_end(text, 2)
      return 0 if index >= text.size
      final = text[index]
      params = text[2...index].split(';').first? || ""
      name = final == '~' && kind == '[' ? TILDE_KEYS[params]? : LETTER_KEYS[final]?
      messages << KeyMsg.new(name) if name
      text[0..index].bytesize
    end

    # The index of the first character in *text* from *start* that is not a digit
    # or semicolon: a sequence's final character.
    private def parameters_end(text : String, start : Int32) : Int32
      text.index(/[^0-9;]/, start) || text.size
    end

    private def control_name(char : Char) : String
      case char
      when '\r', '\n'         then "enter"
      when '\t'               then "tab"
      when '\u007F', '\b'     then "backspace"
      when '\u0000'           then "ctrl+space"
      when '\u0001'..'\u001A' then "ctrl+#{(char.ord + 96).chr}"
      else                         char.to_s
      end
    end

    # *data* split into the text of its complete characters, and the bytes of a
    # final character that has not fully arrived.
    private def split_utf8(data : Bytes) : {String, Bytes}
      (1..Math.min(3, data.size)).each do |back|
        byte = data[data.size - back]
        next if byte & 0xC0 == 0x80
        needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
        return {String.new(data[0, data.size - back]).scrub, data[(data.size - back)..].dup} if needed > back
        break
      end
      {String.new(data).scrub, Bytes.empty}
    end
  end
end
