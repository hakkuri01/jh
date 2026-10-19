require "../../spec_helper"
require "../../../src/jekyll_hyde/hyde/wildcard_filter"
require "../../../src/jekyll_hyde/core/response"

private alias Filter = JekyllHyde::Hyde::WildcardFilter

private def response(status : Int32, size : Int64, words : Int32, lines : Int32) : JekyllHyde::Core::Response
  JekyllHyde::Core::Response.new("http://h/x", status, size, words, lines)
end

describe JekyllHyde::Hyde::WildcardFilter do
  it "matches a response whose status and every set dimension agree" do
    filter = Filter.new(404, size: 120_i64, words: 10, lines: 4)
    filter.matches?(response(404, 120_i64, 10, 4)).should be_true
  end

  it "does not match when the status differs" do
    filter = Filter.new(404, size: 120_i64)
    filter.matches?(response(200, 120_i64, 10, 4)).should be_false
  end

  it "does not match when a set dimension differs" do
    filter = Filter.new(404, size: 120_i64, words: 10)
    filter.matches?(response(404, 121_i64, 10, 4)).should be_false # size off by one
    filter.matches?(response(404, 120_i64, 11, 4)).should be_false # words off by one
  end

  it "ignores dimensions left unset, matching on status and the set ones only" do
    filter = Filter.new(403, lines: 2) # only lines constrained
    filter.matches?(response(403, 999_i64, 42, 2)).should be_true
    filter.matches?(response(403, 999_i64, 42, 3)).should be_false
  end

  it "never matches when no dimension is set (calibration always sets one)" do
    Filter.new(404).matches?(response(404, 0_i64, 0, 0)).should be_false
  end

  it "compares by value so accumulated filters deduplicate" do
    Filter.new(404, size: 10_i64).should eq(Filter.new(404, size: 10_i64))
  end
end
