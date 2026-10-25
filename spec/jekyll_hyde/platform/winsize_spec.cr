require "../../spec_helper"
require "../../../src/jekyll_hyde/platform/winsize"

# Exercise the real ioctl path (not the {80,24} fallback) by opening a pty at a
# known size and reading it back. openpty creates a terminal with no controlling
# tty, so it works in CI and the sandbox. Guarded to the platforms that bind the
# ioctl; on Linux openpty lives in libutil, on macOS in libSystem.
{% if flag?(:darwin) || flag?(:linux) %}
  {% if flag?(:linux) %}@[Link("util")]{% end %}
  lib LibPtyTest
    struct Winsize
      cells : UInt16[4]
    end

    fun openpty(aprimary : Int32*, areplica : Int32*, name : UInt8*, termp : Void*, winp : Winsize*) : Int32
  end

  describe JekyllHyde::Platform do
    it "reads the real terminal size back from a known-size pty" do
      ws = LibPtyTest::Winsize.new
      ws.cells[0] = 40_u16  # rows
      ws.cells[1] = 120_u16 # columns
      primary = 0
      replica = 0
      opened = LibPtyTest.openpty(pointerof(primary), pointerof(replica), Pointer(UInt8).null, Pointer(Void).null, pointerof(ws))
      opened.should eq(0)
      io = IO::FileDescriptor.new(replica) # owns and closes the replica fd
      begin
        JekyllHyde::Platform.terminal_size(io).should eq({120, 40})
      ensure
        io.close
        LibC.close(primary)
      end
    end
  end
{% end %}
