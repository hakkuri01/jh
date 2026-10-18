require "../../spec_helper"
require "../../../src/jekyll_hyde/core/response"

describe JekyllHyde::Core::Response do
  it "holds the probed URL and its measured counts" do
    result = JekyllHyde::Core::Response.new("https://x/admin", 200, 512_i64, 40, 12)
    result.url.should eq("https://x/admin")
    result.status.should eq(200)
    result.size.should eq(512)
    result.words.should eq(40)
    result.lines.should eq(12)
    result.location.should be_nil
  end

  it "carries a redirect location when present" do
    result = JekyllHyde::Core::Response.new("https://x/old", 301, 0_i64, 1, 1, "https://x/new")
    result.location.should eq("https://x/new")
  end

  describe "counting builders" do
    body = "hello world\nfoo\n".to_slice # 16 bytes

    it "counts a body the Jekyll way (raw bytes)" do
      result = JekyllHyde::Core::Response.jekyll("https://x/a", 200, body, nil)
      result.size.should eq(16)
      result.words.should eq(2)
      result.lines.should eq(3)
    end

    it "counts a body the Hyde way (decoded text)" do
      result = JekyllHyde::Core::Response.hyde("https://x/a", 200, body, nil)
      result.size.should eq(16)
      result.words.should eq(3)
      result.lines.should eq(2)
    end
  end
end
