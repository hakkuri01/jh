require "../../spec_helper"
require "../../../src/jekyll_hyde/render/sanitize"

describe JekyllHyde::Render do
  describe ".sanitize" do
    it "keeps printable text unchanged" do
      JekyllHyde::Render.sanitize("/admin/login.php").should eq("/admin/login.php")
    end

    it "strips an escape sequence a hostile path could inject" do
      injected = "/a\e[2J\e[1;1H/evil"
      clean = JekyllHyde::Render.sanitize(injected)
      clean.should_not contain('\e')
      clean.should eq("/a·[2J·[1;1H/evil")
    end

    it "strips C0 controls including newline and tab" do
      JekyllHyde::Render.sanitize("a\tb\nc\rd").should eq("a·b·c·d")
    end

    it "strips DEL and C1 controls" do
      JekyllHyde::Render.sanitize("a\u007Fb\u0085c").should eq("a·b·c")
    end

    it "strips bidi overrides and isolates that could reorder a line" do
      JekyllHyde::Render.sanitize("user\u202Egnp.txt").should eq("user·gnp.txt")
      JekyllHyde::Render.sanitize("a\u2066b\u2069c").should eq("a·b·c")
    end
  end
end
