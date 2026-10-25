# The one platform-specific bit jh needs: the terminal size, read with the
# TIOCGWINSZ ioctl so there is no shell out. The request number differs per OS
# (macOS encodes the struct size into it, Linux uses a bare magic number),
# selected at compile time; any other target falls back to the caller's default.
module JekyllHyde::Platform
  {% if flag?(:darwin) || flag?(:linux) %}
    # `ioctl` is variadic in C and must be declared variadic, or the winsize
    # pointer lands in the wrong place: on Apple silicon fixed and variadic
    # arguments use different registers, so a fixed third parameter reads nothing,
    # the call still returns 0, and the size silently collapses to the fallback.
    lib LibTerminal
      {% if flag?(:darwin) %}
        TIOCGWINSZ = 0x40087468_u64
      {% else %}
        TIOCGWINSZ = 0x5413_u64
      {% end %}

      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    end
  {% end %}

  # The terminal size on *io* as {columns, rows}, or nil when it cannot be read
  # (a non-terminal fd, a zero-sized window, or an unsupported platform). The
  # winsize struct is four unsigned shorts, rows first; one read fills all four.
  def self.terminal_size(io : IO::FileDescriptor = STDOUT) : {Int32, Int32}?
    {% if flag?(:darwin) || flag?(:linux) %}
      size = StaticArray(UInt16, 4).new(0_u16)
      return unless LibTerminal.ioctl(io.fd, LibTerminal::TIOCGWINSZ, pointerof(size)) == 0
      rows, columns = size[0], size[1]
      return if columns == 0 || rows == 0
      {columns.to_i, rows.to_i}
    {% else %}
      nil
    {% end %}
  end
end
