require "../../spec_helper"
require "../../../src/jekyll_hyde/hyde/sim_hash"
require "../../../src/jekyll_hyde/hyde/similarity_filter"

private alias SH = JekyllHyde::Hyde::SimHash

# The message for the official vectors is bytes 0x00, 0x01, ... 0x(n-1).
private def msg(n : Int32) : Bytes
  Bytes.new(n, &.to_u8)
end

describe JekyllHyde::Hyde::SimHash do
  it "matches the official SipHash-2-4 vectors (key bytes 00..0f)" do
    k0 = 0x0706050403020100_u64
    k1 = 0x0f0e0d0c0b0a0908_u64
    SH.siphash24(msg(0), k0, k1).should eq(0x726fdb47dd0e0e31_u64)
    SH.siphash24(msg(1), k0, k1).should eq(0x74f839c593dc67fd_u64)
    SH.siphash24(msg(7), k0, k1).should eq(0xab0200f58b01d137_u64)
    SH.siphash24(msg(8), k0, k1).should eq(0x93f5f5799a932462_u64)
    SH.siphash24(msg(15), k0, k1).should eq(0xa129ca6149be45e5_u64)
  end

  it "preprocesses text into the expected token stream" do
    SH.preprocess("WHY are Y'all YELLing?").should eq(["y", "all", "yelling"])
  end

  it "is stable and zero-distance to itself" do
    sig = SH.signature("the quick brown fox jumps over the lazy dog")
    SH.signature("the quick brown fox jumps over the lazy dog").should eq(sig)
    SH.hamming(sig, sig).should eq(0)
  end

  it "places a soft-404 near its duplicate and far from distinct content" do
    # "not" is a stop word, so both reduce to the token "found".
    not_found = SH.signature("not found")
    SH.hamming(not_found, SH.signature("found")).should be <= 3
    distinct = SH.signature("a genuine content page with many unique descriptive words")
    SH.hamming(not_found, distinct).should be > 3
  end
end

describe JekyllHyde::Hyde::SimilarityFilter do
  it "drops near-duplicates of the learned page, keeps distinct ones" do
    filter = JekyllHyde::Hyde::SimilarityFilter.from("not found")
    filter.matches?(SH.signature("found")).should be_true
    filter.matches?(SH.signature("an entirely different and far longer unique document body here")).should be_false
  end
end
