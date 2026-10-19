require "../../spec_helper"
require "../../../src/jekyll_hyde/hyde/tuner"

describe JekyllHyde::Hyde::Tuner do
  it "does nothing when disabled (the default policy)" do
    tuner = JekyllHyde::Hyde::Tuner.new(10)
    100.times { tuner.observe(429) }
    tuner.concurrency.should eq(10)
  end

  it "holds concurrency until a full round of requests" do
    tuner = JekyllHyde::Hyde::Tuner.new(10, enabled: true)
    49.times { tuner.observe(429) }
    tuner.concurrency.should eq(10)
  end

  it "backs off when 429s exceed the threshold" do
    tuner = JekyllHyde::Hyde::Tuner.new(10, enabled: true)
    50.times { tuner.observe(429) }
    tuner.concurrency.should eq(5)
  end

  it "backs off on excessive request errors" do
    tuner = JekyllHyde::Hyde::Tuner.new(10, enabled: true)
    50.times { tuner.observe(0, error: true) }
    tuner.concurrency.should eq(5)
  end

  it "does not back off on a healthy mix" do
    tuner = JekyllHyde::Hyde::Tuner.new(10, enabled: true)
    100.times { tuner.observe(200) }
    tuner.concurrency.should eq(10)
  end

  it "recovers concurrency once a flood subsides, instead of latching down" do
    tuner = JekyllHyde::Hyde::Tuner.new(50, enabled: true)
    50.times { tuner.observe(429) } # one bad window: halve to 25
    tuner.concurrency.should eq(25)
    50.times { tuner.observe(200) } # a clean window: double back toward 50
    tuner.concurrency.should eq(50)
  end

  it "does not keep halving across consecutive clean windows after one bad one" do
    tuner = JekyllHyde::Hyde::Tuner.new(50, enabled: true)
    50.times { tuner.observe(0, error: true) } # halve to 25
    100.times { tuner.observe(200) }           # two clean windows
    tuner.concurrency.should eq(50)            # recovered and capped at the original
  end
end
