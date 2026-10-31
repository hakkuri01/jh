require "../spec_helper"
require "../support/fixture_server"
require "../support/wordlists"
require "../../src/jekyll_hyde/scan_builder"

describe JekyllHyde::ScanBuilder do
  it "rejects an invalid target at the one build-path validation home (AGENTS Security 9)" do
    config = JekyllHyde::ScanConfig.new
    config.url = "not a url"
    config.wordlists = ["/tmp/whatever.txt"]
    expect_raises(ArgumentError, "valid URL") do
      JekyllHyde::ScanBuilder.build(config)
    end
  end

  it "builds a Hyde engine for HYDE and a Jekyll engine for JEKYLL" do
    path = wordlist_file("admin")
    begin
      hyde = JekyllHyde::ScanConfig.new
      hyde.mode = "HYDE"
      hyde.url = "http://127.0.0.1:9"
      hyde.wordlists = [path]
      JekyllHyde::ScanBuilder.build(hyde).should be_a(JekyllHyde::Hyde::Scan)

      jekyll = JekyllHyde::ScanConfig.new
      jekyll.mode = "JEKYLL"
      jekyll.url = "http://127.0.0.1:9/FUZZ"
      jekyll.wordlists = [path]
      JekyllHyde::ScanBuilder.build(jekyll).should be_a(JekyllHyde::Jekyll::Scan)
    ensure
      File.delete(path)
    end
  end

  it "sends HTTP Basic auth derived from the target userinfo, as ffuf and feroxbuster do" do
    server = FixtureServer.new({} of String => FixtureServer::Route)
    path = wordlist_file("admin")
    begin
      config = JekyllHyde::ScanConfig.new
      config.mode = "HYDE"
      config.url = "http://user:pass@127.0.0.1:#{server.port}"
      config.wordlists = [path]
      config.threads = 2
      config.depth = 1
      JekyllHyde::ScanBuilder.build(config).run
      # "user:pass" -> Base64 -> dXNlcjpwYXNz, on every request the walk makes
      server.received_headers.any? { |h| h["Authorization"]? == "Basic dXNlcjpwYXNz" }.should be_true
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "does not override an Authorization header the operator already set" do
    server = FixtureServer.new({} of String => FixtureServer::Route)
    path = wordlist_file("admin")
    begin
      config = JekyllHyde::ScanConfig.new
      config.mode = "HYDE"
      config.url = "http://user:pass@127.0.0.1:#{server.port}"
      config.wordlists = [path]
      config.headers = ["Authorization: Bearer OPTOKEN"]
      config.threads = 2
      config.depth = 1
      JekyllHyde::ScanBuilder.build(config).run
      sent = server.received_headers
      sent.any? { |h| h["Authorization"]? == "Bearer OPTOKEN" }.should be_true
      sent.any? { |h| h["Authorization"]?.try(&.starts_with?("Basic")) }.should be_false
    ensure
      server.stop
      File.delete(path)
    end
  end
end
