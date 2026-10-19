require "../../spec_helper"
require "../../../src/jekyll_hyde/core/results"

private def result(url : String, status : Int32, size = 0_i64, words = 1, lines = 1, location : String? = nil)
  JekyllHyde::Core::Response.new(url, status, size, words, lines, location)
end

describe JekyllHyde::Core::Results do
  it "starts empty and exports an empty JSON array" do
    results = JekyllHyde::Core::Results.new
    results.empty?.should be_true
    results.size.should eq(0)
    results.to_json.should eq("[]")
  end

  it "appends kept results in order" do
    results = JekyllHyde::Core::Results.new
    results << result("https://x/a", 200)
    results << result("https://x/b", 301, location: "https://x/c")
    results.size.should eq(2)
    results.entries.map(&.url).should eq(["https://x/a", "https://x/b"])
  end

  it "exports JSON with a null location when absent" do
    results = JekyllHyde::Core::Results.new
    results << result("https://x/a", 200, 512_i64, 40, 12)
    row = JSON.parse(results.to_json)[0]
    row["url"].as_s.should eq("https://x/a")
    row["status"].as_i.should eq(200)
    row["size"].as_i.should eq(512)
    row["words"].as_i.should eq(40)
    row["lines"].as_i.should eq(12)
    row["location"].raw.should be_nil
  end

  it "exports CSV with a header and quotes hostile fields" do
    results = JekyllHyde::Core::Results.new
    results << result("https://x/a,b", 200)
    lines = results.to_csv.lines
    lines.first.should eq("url,status,size,words,lines,location")
    lines[1].should start_with(%("https://x/a,b",200,))
  end

  it "neutralizes a CSV formula in a hostile redirect location" do
    results = JekyllHyde::Core::Results.new
    results << result("https://x/go", 301, location: "=HYPERLINK(\"http://evil\")")
    cells = results.to_csv.lines[1]
    cells.should contain("'=HYPERLINK") # a leading = is quoted off so no formula runs
    cells.should_not contain(",=HYPERLINK")
  end

  it "sanitizes an escape sequence out of exported fields" do
    results = JekyllHyde::Core::Results.new
    results << result("https://x/a\e[2Jb", 200, location: "https://x/c\e[1md")
    results.to_json.should_not contain('\e')
    results.to_csv.should_not contain('\e')
  end
end
