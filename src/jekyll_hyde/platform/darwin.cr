# Platform specifics, isolated here (one file per platform). Only the terminal
# size for now, read with an ioctl so there is no shell out.
module JekyllHyde::Platform
  {% if flag?(:darwin) %}
    # `ioctl` is variadic in C; it must be declared variadic so the winsize
    # pointer is passed correctly (on Apple silicon, fixed and variadic
    # arguments use different registers).
    lib LibDarwinTerminal
      # macOS TIOCGWINSZ: fills a `struct winsize` of four unsigned shorts.
      TIOCGWINSZ = 0x40087468_u64

      fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    end
  {% end %}

  # The terminal size on *io* as {columns, rows}, or nil when it cannot be read.
  def self.terminal_size(io : IO::FileDescriptor = STDOUT) : {Int32, Int32}?
    {% if flag?(:darwin) %}
      size = StaticArray(UInt16, 4).new(0_u16)
      return unless LibDarwinTerminal.ioctl(io.fd, LibDarwinTerminal::TIOCGWINSZ, pointerof(size)) == 0
      rows, columns = size[0], size[1]
      return if columns == 0 || rows == 0
      {columns.to_i, rows.to_i}
    {% else %}
      nil
    {% end %}
  end
end
