require "../../spec_helper"
require "../../../src/jekyll_hyde/jekyll/value_range"

describe JekyllHyde::Jekyll::ValueRange do
  it "parses a single value into a one-wide range" do
    range = JekyllHyde::Jekyll::ValueRange.parse("200")
    range.min.should eq(200)
    range.max.should eq(200)
    range.includes?(200).should be_true
    range.includes?(201).should be_false
  end

  it "parses a min-max range inclusively" do
    range = JekyllHyde::Jekyll::ValueRange.parse("200-299")
    range.includes?(200).should be_true
    range.includes?(250).should be_true
    range.includes?(299).should be_true
    range.includes?(300).should be_false
  end

  it "rejects an inverted range" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::ValueRange.parse("300-200") }
  end

  it "rejects a non-number" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::ValueRange.parse("abc") }
  end
end
