require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/jekyll/scan"

private def wordlist(*words : String) : JekyllHyde::Wordlist::List
  JekyllHyde::Wordlist::List.new(words.to_a)
end

private def found(results : JekyllHyde::Core::Results, origin : String)
  results.entries.map { |r| {r.url.sub(origin, ""), r.status} }.to_set
end

describe JekyllHyde::Jekyll::Scan do
  it "fuzzes FUZZ across the wordlist and keeps only matched responses" do
    server = FixtureServer.new({
      "/admin" => FixtureServer::Route.new(200, "ok"),
      "/login" => FixtureServer::Route.new(301, "", location: "/login/"),
    })
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      results = JekyllHyde::Jekyll::Scan.new(template, wordlist("admin", "login", "nope"), concurrency: 4).run
      hits = found(results, server.base)
      hits.should contain({"/admin", 200})
      hits.should contain({"/login", 301})
      hits.map(&.first).should_not contain("/nope") # 404 is not in the default matcher
    ensure
      server.stop
    end
  end

  it "honors a custom matcher" do
    server = FixtureServer.new({"/x" => FixtureServer::Route.new(200, "ok")})
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      rules = JekyllHyde::Jekyll::Rules.new([JekyllHyde::Jekyll::Rule.build("status", "all")])
      results = JekyllHyde::Jekyll::Scan.new(template, wordlist("x", "missing"), concurrency: 2, rules: rules).run
      # "all" keeps the 404 for /missing too
      found(results, server.base).should eq(Set{ {"/x", 200}, {"/missing", 404} })
    ensure
      server.stop
    end
  end

  it "applies a size filter, dropping responses it matches" do
    server = FixtureServer.new({
      "/keep" => FixtureServer::Route.new(200, "yes"), # 3-byte body
      "/drop" => FixtureServer::Route.new(200, "no"),  # 2-byte body
    })
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      rules = JekyllHyde::Jekyll::Rules.new(
        [JekyllHyde::Jekyll::Rule.build("status", "all")],
        [JekyllHyde::Jekyll::Rule.build("size", "2")],
      )
      results = JekyllHyde::Jekyll::Scan.new(template, wordlist("keep", "drop"), concurrency: 2, rules: rules).run
      paths = found(results, server.base).map(&.first)
      paths.should contain("/keep")
      paths.should_not contain("/drop")
    ensure
      server.stop
    end
  end

  it "auto-calibrates a wildcard host, filtering the constant 200s" do
    server = FixtureServer.new({"/real" => FixtureServer::Route.new(200, "a genuinely longer unique body")}, wildcard: true)
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      words = wordlist("real", "nope1", "nope2")
      plain = JekyllHyde::Jekyll::Scan.new(template, words, concurrency: 3).run
      plain.entries.size.should eq(3) # every path is a 200, so all are kept
      calibrated = JekyllHyde::Jekyll::Scan.new(template, words, concurrency: 3, auto_calibrate: true).run
      kept = found(calibrated, server.base).map(&.first)
      kept.should eq(["/real"]) # the constant wildcard 200s are filtered away
    ensure
      server.stop
    end
  end

  it "fuzzes two keywords as a clusterbomb product" do
    server = FixtureServer.new({
      "/api/users"   => FixtureServer::Route.new(200, "ok"),
      "/admin/users" => FixtureServer::Route.new(200, "ok"),
    })
    begin
      input = JekyllHyde::Jekyll::Input.new([
        JekyllHyde::Jekyll::Source.new("FUZZ", wordlist("api", "admin")),
        JekyllHyde::Jekyll::Source.new("FUZ2Z", wordlist("users", "nope")),
      ])
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ/FUZ2Z", input.keywords)
      results = JekyllHyde::Jekyll::Scan.new(template, input, concurrency: 4).run
      hits = found(results, server.base)
      hits.should contain({"/api/users", 200})
      hits.should contain({"/admin/users", 200})
      hits.map(&.first).should_not contain("/api/nope")
    ensure
      server.stop
    end
  end

  it "substitutes FUZZ into a header, not only the URL" do
    server = FixtureServer.new({"/ping" => FixtureServer::Route.new(200, "ok")})
    begin
      # FUZZ lives only in the header here; the URL is static.
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/ping", ["FUZZ"])
      options = JekyllHyde::Http::Options.jekyll(headers: ["X-Fuzz: FUZZ"])
      rules = JekyllHyde::Jekyll::Rules.new([JekyllHyde::Jekyll::Rule.build("status", "all")])
      JekyllHyde::Jekyll::Scan.new(template, wordlist("alpha", "beta"), options, concurrency: 2, rules: rules).run
      sent = server.received_headers.compact_map { |h| h["X-Fuzz"]? }.to_set
      sent.should eq(Set{"alpha", "beta"})
    ensure
      server.stop
    end
  end

  it "sends the operator method on every fuzzed request" do
    server = FixtureServer.new({} of String => FixtureServer::Route, wildcard: true)
    begin
      template = JekyllHyde::Jekyll::Template.new("#{server.base}/FUZZ")
      options = JekyllHyde::Http::Options.jekyll(method: "HEAD")
      rules = JekyllHyde::Jekyll::Rules.new([JekyllHyde::Jekyll::Rule.build("status", "all")])
      JekyllHyde::Jekyll::Scan.new(template, wordlist("a", "b"), options, concurrency: 2, rules: rules).run
      server.received_methods.uniq.should eq(["HEAD"])
    ensure
      server.stop
    end
  end
end
