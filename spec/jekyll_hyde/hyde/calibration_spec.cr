require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/hyde/calibration"
require "../../../src/jekyll_hyde/hyde/sim_hash"

describe JekyllHyde::Hyde::Calibration do
  it "learns a 404 fingerprint from a plain not-found server" do
    server = FixtureServer.new
    begin
      filters = JekyllHyde::Hyde::Calibration.new(server.base).learn.wildcards
      filters.size.should eq(1)
      filter = filters.first
      filter.status.should eq(404)
      filter.size.should eq(9) # "not found"
      filter.words.should eq(2)
      filter.lines.should eq(1)
    ensure
      server.stop
    end
  end

  it "learns a 200 wildcard fingerprint when every path answers 200" do
    server = FixtureServer.new(wildcard: true)
    begin
      filters = JekyllHyde::Hyde::Calibration.new(server.base).learn.wildcards
      filters.size.should eq(1)
      filter = filters.first
      filter.status.should eq(200)
      filter.size.should eq(8) # "wildcard"
    ensure
      server.stop
    end
  end

  it "drops a response matching the learned fingerprint and keeps a real one" do
    server = FixtureServer.new(wildcard: true)
    begin
      filter = JekyllHyde::Hyde::Calibration.new(server.base).learn.wildcards.first
      wildcard = JekyllHyde::Core::Response.new("u", 200, 8_i64, 1, 1)
      real = JekyllHyde::Core::Response.new("u", 200, 500_i64, 50, 10)
      filter.matches?(wildcard).should be_true
      filter.matches?(real).should be_false
    ensure
      server.stop
    end
  end

  it "also learns a SimHash similarity filter from the soft-404 body" do
    server = FixtureServer.new
    begin
      sims = JekyllHyde::Hyde::Calibration.new(server.base).learn.similarities
      sims.size.should eq(1)
      # the learned page is "not found"; "found" is its near-duplicate
      sims.first.matches?(JekyllHyde::Hyde::SimHash.signature("found")).should be_true
      sims.first.matches?(JekyllHyde::Hyde::SimHash.signature("a totally different page body")).should be_false
    ensure
      server.stop
    end
  end
end
