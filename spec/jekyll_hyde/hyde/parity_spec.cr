require "../../spec_helper"
require "../../support/fixture_server"
require "../../support/parity"
require "../../../src/jekyll_hyde/hyde/scan"

private alias H = JekyllHyde::Hyde
private alias Route = FixtureServer::Route

private def wordlist(*words : String) : JekyllHyde::Wordlist::List
  JekyllHyde::Wordlist::List.new(words.to_a)
end

# The kept findings of a scan, as origin-stripped paths.
private def kept(scan : H::Scan, origin : String) : Set(String)
  scan.run.entries.map(&.url.sub(origin, "")).to_set
end

# Run one scenario against a fresh loopback fixture, pairing jh's findings with
# an independently derived expected set, hand-authored for each route tree.
private def scenario(name : String, routes : Hash(String, Route), expected : Set(String), *, wildcard : Bool = false, & : String -> H::Scan) : Parity::Scenario
  server = FixtureServer.new(routes, wildcard: wildcard)
  begin
    Parity::Scenario.new(name, expected, kept(yield(server.base), server.base))
  ensure
    server.stop
  end
end

# Flat discovery and soft-404 filtering: distinct real statuses are kept; the
# constant-404 misses (and a wholly wildcard host) are learned by calibration
# and dropped.
private def discovery_scenarios : Array(Parity::Scenario)
  [
    scenario("flat-discovery",
      {"/alpha" => Route.new(200, "ALPHA"), "/bravo" => Route.new(403, "NOPE"), "/charlie" => Route.new(500, "BOOM")},
      Set{"/alpha", "/bravo", "/charlie"}) do |b|
      H::Scan.new(b, wordlist("alpha", "bravo", "charlie", "miss1", "miss2"), concurrency: 5)
    end,
    scenario("wildcard", {"/unique" => Route.new(200, "a much longer unique body")}, Set{"/unique"}, wildcard: true) do |b|
      H::Scan.new(b, wordlist("unique", "miss1", "miss2"), concurrency: 3)
    end,
    scenario("base-dir-reported",
      {"/" => Route.new(200, "<h1>home distinct content</h1>"), "/admin" => Route.new(200, "admin distinct content")},
      Set{"/", "/admin"}) do |b|
      H::Scan.new(b, wordlist("admin", "nope"), concurrency: 3)
    end,
  ]
end

# Link mining: href/src/action links and robots.txt Disallow paths are followed,
# their parent sub-paths expanded. robots.txt is a seed, not a reported finding.
# The discovered page carries a distinct body so the SimHash soft-404 fallback
# does not fold it into the 404 (that fallback is covered on its own, below).
private def extraction_scenarios : Array(Parity::Scenario)
  [
    scenario("link-extraction",
      {"/index" => Route.new(200, %(<a href="/found.html">x</a>)), "/found.html" => Route.new(200, "a genuinely discovered document page")},
      Set{"/index", "/found.html"}) do |b|
      H::Scan.new(b, wordlist("index", "nope"), concurrency: 3)
    end,
    scenario("robots-seeding",
      {"/robots.txt" => Route.new(200, "User-agent: *\nDisallow: /hidden\n"), "/hidden" => Route.new(200, "SECRET")},
      Set{"/hidden"}) do |b|
      H::Scan.new(b, wordlist("nope"), concurrency: 2)
    end,
  ]
end

# Recursion: a 3xx to url+/ and a 2xx directory (a url ending in /) are
# descended, and the depth bound stops the walk (depth - base >= max).
private def recursion_scenarios : Array(Parity::Scenario)
  nested = {
    "/a"     => Route.new(301, "", location: "/a/"),
    "/a/b"   => Route.new(301, "", location: "/a/b/"),
    "/a/b/c" => Route.new(200, "DEEP"),
  }
  [
    scenario("recursion-301", {"/app" => Route.new(301, "", location: "/app/"), "/app/config" => Route.new(200, "CONFIG")}, Set{"/app", "/app/config"}) do |b|
      H::Scan.new(b, wordlist("app", "config", "nope"), concurrency: 4)
    end,
    scenario("recursion-2xx-dir",
      {"/index" => Route.new(200, %(<a href="/area/file.js">x</a>)), "/area/" => Route.new(200, "AREA"), "/area/file.js" => Route.new(200, "JS")},
      Set{"/index", "/area/", "/area/file.js"}) do |b|
      H::Scan.new(b, wordlist("index"), concurrency: 3)
    end,
    scenario("depth-unbounded", nested, Set{"/a", "/a/b", "/a/b/c"}) do |b|
      H::Scan.new(b, wordlist("a", "b", "c"), concurrency: 3, max_depth: 4)
    end,
    scenario("depth-capped-2", nested, Set{"/a", "/a/b"}) do |b|
      H::Scan.new(b, wordlist("a", "b", "c"), concurrency: 3, max_depth: 2)
    end,
  ]
end

describe "Hyde parity vs the fixture" do
  it "reproduces the expected findings exactly across the scenarios" do
    scenarios = discovery_scenarios + extraction_scenarios + recursion_scenarios
    score = Parity.score(scenarios)
    puts "\nHyde parity vs fixture: #{(score * 100).round(1)}% over #{scenarios.size} scenarios\n#{Parity.report(scenarios)}"
    scenarios.all?(&.clean?).should be_true # exact: no missing and no extra finding in any scenario
  end
end
