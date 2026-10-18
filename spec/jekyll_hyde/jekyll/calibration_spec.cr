require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/jekyll/calibration"

describe JekyllHyde::Jekyll::Calibration do
  it "learns a size filter from a wildcard host whose 200s are constant" do
    server = FixtureServer.new(wildcard: true) # every path -> 200 "wildcard" (8 bytes)
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      learned = JekyllHyde::Jekyll::Calibration.new(template, JekyllHyde::Jekyll::Rules.default, concurrency: 4).learn
      learned.size.should eq(1) # deduped across the three groups
      # the learned filter drops a wildcard-shaped response and keeps a different one
      wildcard = JekyllHyde::Jekyll::Candidate.new(JekyllHyde::Core::Response.new("u", 200, 8_i64, 1, 1), "wildcard".to_slice, Time::Span.zero)
      other = JekyllHyde::Jekyll::Candidate.new(JekyllHyde::Core::Response.new("u", 200, 40_i64, 9, 3), Bytes.empty, Time::Span.zero)
      learned.first.matches?(wildcard).should be_true
      learned.first.matches?(other).should be_false
    ensure
      server.stop
    end
  end

  it "learns nothing from a host that returns proper 404s" do
    server = FixtureServer.new({"/real" => FixtureServer::Route.new(200, "ok")})
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      learned = JekyllHyde::Jekyll::Calibration.new(template, JekyllHyde::Jekyll::Rules.default, concurrency: 4).learn
      learned.should be_empty # random probes 404, not in the default matcher, so nothing calibrates
    ensure
      server.stop
    end
  end
end
