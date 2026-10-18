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
end
