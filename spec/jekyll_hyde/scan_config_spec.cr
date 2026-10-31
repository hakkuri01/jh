require "../spec_helper"
require "../../src/jekyll_hyde/scan_config"

describe JekyllHyde::ScanConfig do
  it "clamps -t into [1, MAX_THREADS] so neither launch path can exhaust memory" do
    config = JekyllHyde::ScanConfig.new
    config.threads = 0
    config.threads.should eq(1)
    config.threads = 50_000
    config.threads.should eq(JekyllHyde::ScanConfig::MAX_THREADS)
    config.threads = 40
    config.threads.should eq(40)
  end

  it "adds a status matcher from a valid field and drops a blank or malformed one" do
    config = JekyllHyde::ScanConfig.new
    config.match_status("")    # blank: dropped, not raised
    config.match_status("   ") # whitespace: dropped
    config.matchers.should be_empty
    config.match_status("200,301") # valid
    config.matchers.size.should eq(1)
    config.match_status("not-a-code") # malformed: dropped, never fatal
    config.matchers.size.should eq(1)
  end

  it "folds a -b cookie into the request headers as a Cookie line, -H headers intact" do
    config = JekyllHyde::ScanConfig.new
    config.headers = ["X-Probe: 1"]
    config.request_headers.should eq(["X-Probe: 1"])
    config.cookie = "session=abc"
    config.request_headers.should eq(["X-Probe: 1", "Cookie: session=abc"])
  end
end
