require "../../spec_helper"
require "../../../src/jekyll_hyde/core/metrics"

private def bytes(str : String) : Bytes
  str.to_slice
end

describe JekyllHyde::Core::Metrics do
  describe "Jekyll counting (raw bytes)" do
    it "counts words as spaces plus one" do
      JekyllHyde::Core::Metrics.jekyll_words(bytes("")).should eq(1)
      JekyllHyde::Core::Metrics.jekyll_words(bytes("a b c")).should eq(3)
      # a newline is not a space, so words do not cross lines
      JekyllHyde::Core::Metrics.jekyll_words(bytes("hello world\nfoo")).should eq(2)
    end

    it "counts lines as newlines plus one" do
      JekyllHyde::Core::Metrics.jekyll_lines(bytes("")).should eq(1)
      JekyllHyde::Core::Metrics.jekyll_lines(bytes("a\nb\n")).should eq(3)
      JekyllHyde::Core::Metrics.jekyll_lines(bytes("a\n\nb")).should eq(3)
    end
  end

  describe "Hyde counting (decoded text)" do
    it "counts whitespace-delimited tokens" do
      JekyllHyde::Core::Metrics.hyde_words("").should eq(0)
      JekyllHyde::Core::Metrics.hyde_words("a b c").should eq(3)
      JekyllHyde::Core::Metrics.hyde_words("hello world\nfoo").should eq(3)
      JekyllHyde::Core::Metrics.hyde_words("  \n  ").should eq(0)
    end

    it "counts newline-split lines, dropping a trailing empty line" do
      JekyllHyde::Core::Metrics.hyde_lines("").should eq(0)
      JekyllHyde::Core::Metrics.hyde_lines("a\nb\n").should eq(2)
      JekyllHyde::Core::Metrics.hyde_lines("a\n\nb").should eq(3)
    end
  end

  it "diverges between the two schemes on the same body" do
    body = "hello world\nfoo\n"
    JekyllHyde::Core::Metrics.jekyll_words(bytes(body)).should eq(2)
    JekyllHyde::Core::Metrics.hyde_words(body).should eq(3)
    JekyllHyde::Core::Metrics.jekyll_lines(bytes(body)).should eq(3)
    JekyllHyde::Core::Metrics.hyde_lines(body).should eq(2)
  end
end
