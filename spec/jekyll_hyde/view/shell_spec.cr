require "../../spec_helper"
require "../../../src/jekyll_hyde/view/shell"
require "../../../src/jekyll_hyde/view/scene"

private def state(mode : String, values : Array(String)) : JekyllHyde::View::Shell::State
  JekyllHyde::View::Shell::State.new(mode, 0, false, values, 0)
end

private def frame(values : Array(String), width : Int32 = 120) : JekyllHyde::Render::Grid
  canvas = JekyllHyde::View::Scene::Canvas.new(width, 40, false)
  JekyllHyde::View::Shell.frame(canvas, state("HYDE", values))
end

# The rendered rows holding the composed `jh …` line, as plain text.
private def command_line(values : Array(String), width : Int32 = 120) : String
  rows = frame(values, width).cells.map { |line| String.build { |io| line.each { |cell| io << cell[0] } } }
  rows.select(&.includes?("jh ")).join("\n")
end

# Bytes allocated per repainted frame for an unchanging form.
private def allocation_per_frame(values : Array(String), frames : Int32 = 60) : Int64
  frame(values) # prime the memo, and the first canvas
  before = GC.stats.total_bytes
  frames.times { frame(values) }
  ((GC.stats.total_bytes - before) // frames).to_i64
end

describe JekyllHyde::View::Shell do
  it "shows depth only in Hyde and the status matcher/filter only in Jekyll" do
    hyde = JekyllHyde::View::Shell.fields("HYDE").map(&.flag)
    jekyll = JekyllHyde::View::Shell.fields("JEKYLL").map(&.flag)
    hyde.should contain("-d")
    hyde.should_not contain("--mc")
    hyde.should_not contain("--fc")
    jekyll.should contain("--mc")
    jekyll.should contain("--fc")
    jekyll.should_not contain("-d")
  end

  it "reads a field value by flag, not index, and returns a blank for a flag absent in the mode" do
    # Hyde fields, in order: -u -w -e -t -d
    st = state("HYDE", ["https://t", "wl.txt", "php", "40", "4"])
    JekyllHyde::View::Shell.value(st, "-u").should eq("https://t")
    JekyllHyde::View::Shell.value(st, "-d").should eq("4")
    JekyllHyde::View::Shell.value(st, "--mc").should eq("") # not a Hyde field
  end

  it "defaults line up with the mode's fields and carry the engine defaults" do
    JekyllHyde::View::Shell.defaults("HYDE").size.should eq(JekyllHyde::View::Shell.fields("HYDE").size)
    JekyllHyde::View::Shell.defaults("JEKYLL").size.should eq(JekyllHyde::View::Shell.fields("JEKYLL").size)
    JekyllHyde::View::Shell.defaults("HYDE").should contain("40") # threads default
  end

  it "is ready only with a target and wordlist, and in Jekyll a FUZZ keyword in the target" do
    JekyllHyde::View::Shell.ready?(state("HYDE", ["https://t", "wl.txt", "", "40", "4"])).should be_true
    JekyllHyde::View::Shell.ready?(state("HYDE", ["", "wl.txt", "", "40", "4"])).should be_false
    JekyllHyde::View::Shell.ready?(state("HYDE", ["https://t", "", "", "40", "4"])).should be_false
    # Jekyll fields, in order: -u -w -e -t --mc --fc
    JekyllHyde::View::Shell.ready?(state("JEKYLL", ["https://t/FUZZ", "wl.txt", "", "40", "", ""])).should be_true
    JekyllHyde::View::Shell.ready?(state("JEKYLL", ["https://t/", "wl.txt", "", "40", "", ""])).should be_false
  end

  describe "the composed command" do
    it "shell-quotes a value a shell would otherwise split, and leaves a plain one bare" do
      shown = command_line(["https://target/a b", "/w/list.txt", "", "40", "4"])
      shown.should contain("'https://target/a b'") # a space is quoted
      shown.should contain("/w/list.txt")          # a plain path is not
      shown.should_not contain("'/w/list.txt'")
    end

    it "rewraps when a value changes, so the memo never shows a stale command" do
      command_line(["https://first", "/w/a.txt", "", "40", "4"]).should contain("https://first")
      # same width and mode, one value different: the cached line must not persist
      second = command_line(["https://second", "/w/a.txt", "", "40", "4"])
      second.should contain("https://second")
      second.should_not contain("https://first")
    end

    it "rewraps when the panel width changes" do
      wide = command_line(["https://target", "/w/a.txt", "", "40", "4"], width: 120)
      narrow = command_line(["https://target", "/w/a.txt", "", "40", "4"], width: 60)
      # the same command wrapped to two different widths cannot be the same rows
      wide.should_not eq(narrow)
    end

    # AGENTS Big O 5 and 7: the wrap is per input change, not per frame, pinned by
    # allocation rather than a wall clock. Repainting an unchanged form must not
    # cost more for a long command than a short one; without the memo the long
    # one allocates a styled cell per character on every frame.
    it "costs the same per repainted frame whatever the command's length" do
      short = allocation_per_frame(["https://t", "/w/a.txt", "", "40", "4"])
      long = allocation_per_frame(["https://t/#{"a" * 600}", "/w/#{"b" * 600}", "#{"c" * 600}", "40", "4"])
      (long - short).abs.should be < 8_192
    end
  end
end
