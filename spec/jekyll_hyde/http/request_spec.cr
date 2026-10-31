require "../../spec_helper"
require "../../../src/jekyll_hyde/http/request"

describe JekyllHyde::Http::Request do
  describe ".headers_from" do
    it "splits each raw line on the first colon, so a value may contain colons" do
      headers = JekyllHyde::Http::Request.headers_from(["X-A: 1", "Cookie: a=b; c=d", "Range: bytes=0-1"])
      headers["X-A"].should eq("1")
      headers["Cookie"].should eq("a=b; c=d")
      headers["Range"].should eq("bytes=0-1")
    end

    it "trims surrounding whitespace from the name and value" do
      headers = JekyllHyde::Http::Request.headers_from(["  X-Trim  :   spaced   "])
      headers["X-Trim"].should eq("spaced")
    end

    it "skips a line with no colon or an empty name (the CLI validates the shape)" do
      headers = JekyllHyde::Http::Request.headers_from(["nocolon", ": novalue-name", "Good: yes"])
      headers["Good"].should eq("yes")
      headers.has_key?("nocolon").should be_false
    end
  end
end
