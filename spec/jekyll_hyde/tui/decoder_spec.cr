require "../../spec_helper"
require "../../../src/jekyll_hyde/tui/decoder"

# The key names a fresh decoder produces from *input*.
private def decode(input : String) : Array(String)
  JekyllHyde::Tui::Decoder.new.feed(input.to_slice).map { |msg| msg.as(JekyllHyde::Tui::KeyMsg).key }
end

describe JekyllHyde::Tui::Decoder do
  it "names printable, control, and run-together keys" do
    decode("a").should eq(["a"])
    decode("\t").should eq(["tab"])
    decode("\r").should eq(["enter"])
    decode("\u0003").should eq(["ctrl+c"])
    decode("ab\t").should eq(["a", "b", "tab"])
  end

  it "names escape sequences and alt keys" do
    decode("\e[A").should eq(["up"])
    decode("\e[Z").should eq(["backtab"])
    decode("\e[3~").should eq(["delete"])
    decode("\ex").should eq(["alt+x"])
  end

  it "drops an unknown escape sequence whole" do
    decode("\e[99y").should be_empty
  end

  it "takes a lone ESC as the escape key only once input stops" do
    decoder = JekyllHyde::Tui::Decoder.new
    decoder.feed("\e".to_slice).should be_empty
    decoder.pending?.should be_true
    decoder.flush.map(&.as(JekyllHyde::Tui::KeyMsg).key).should eq(["esc"])
  end

  it "reassembles a multibyte character split across reads" do
    decoder = JekyllHyde::Tui::Decoder.new
    decoder.feed(Bytes[0xC3]).should be_empty
    decoder.feed(Bytes[0xA9]).map(&.as(JekyllHyde::Tui::KeyMsg).key).should eq(["é"])
  end
end
