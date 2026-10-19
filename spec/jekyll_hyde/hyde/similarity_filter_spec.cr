require "../../spec_helper"
require "../../../src/jekyll_hyde/hyde/similarity_filter"

private alias Filter = JekyllHyde::Hyde::SimilarityFilter
private alias SimHash = JekyllHyde::Hyde::SimHash

describe JekyllHyde::Hyde::SimilarityFilter do
  it "matches a page that is an exact duplicate of the one it learned" do
    page = "the requested page was not found on this server, please check the address"
    filter = Filter.from(page)
    filter.matches?(SimHash.signature(page)).should be_true
  end

  it "does not match a clearly different page" do
    filter = Filter.from("the requested page was not found on this server")
    other = SimHash.signature("a long and genuinely different document full of real unique content here")
    filter.matches?(other).should be_false
  end

  it "matches within the cutoff bits and rejects beyond it" do
    base = "error four oh four the page you requested could not be located on this host"
    filter = Filter.from(base, cutoff: 3)
    filter.matches?(filter.hash ^ 0b11_u64).should be_true    # 2 flipped bits <= cutoff 3
    filter.matches?(filter.hash ^ 0b1111_u64).should be_false # 4 flipped bits > cutoff 3
  end

  it "is equal by signature so a scan deduplicates identical learned filters" do
    page = "not found"
    Filter.from(page).should eq(Filter.from(page))
  end
end
