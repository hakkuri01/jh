require "../../spec_helper"
require "../../support/fixture_server"
require "../../support/parity"
require "../../../src/jekyll_hyde/jekyll/scan"

private alias J = JekyllHyde::Jekyll
private alias Route = FixtureServer::Route

private def wordlist(*words : String) : JekyllHyde::Wordlist::List
  JekyllHyde::Wordlist::List.new(words.to_a)
end

# The seven-entry wordlist the status/size tree scenarios share; "ghost" is the
# one entry with no route, so it exercises the default-404 path.
private def words : JekyllHyde::Wordlist::List
  wordlist("alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "ghost")
end

# The kept findings of a scan, as origin-stripped paths.
private def kept(scan : J::Scan, origin : String) : Set(String)
  scan.run.entries.map(&.url.sub(origin, "")).to_set
end

# Run one scenario against a fresh loopback fixture, pairing jh's findings with
# an independently derived expected set, hand-authored for each route tree.
private def scenario(name : String, routes : Hash(String, Route), expected : Set(String), *, wildcard : Bool = false, & : String -> J::Scan) : Parity::Scenario
  server = FixtureServer.new(routes, wildcard: wildcard)
  begin
    Parity::Scenario.new(name, expected, kept(yield(server.base), server.base))
  ensure
    server.stop
  end
end

private def status_rules(value : String, filters : Array(J::Rule) = [] of J::Rule) : J::Rules
  J::Rules.new([J::Rule.build("status", value)], filters)
end

# The main status/size tree: one route per status class, each body a known size
# (AAAA=4, ""=0, FORBID=6, ERR=3, CREATED=7, TEA=3; the default 404 body is 9).
private def tree : Hash(String, Route)
  {
    "/alpha"   => Route.new(200, "AAAA"),
    "/bravo"   => Route.new(301, "", location: "/bravo/"),
    "/charlie" => Route.new(403, "FORBID"),
    "/delta"   => Route.new(500, "ERR"),
    "/echo"    => Route.new(201, "CREATED"),
    "/foxtrot" => Route.new(418, "TEA"),
  }
end

# The status matcher: the default -mc set keeps four classes; a narrowed set
# and a range keep fewer; and-mode needs status and size to both match.
private def status_scenarios : Array(Parity::Scenario)
  [
    scenario("default-mc", tree, Set{"/alpha", "/bravo", "/charlie", "/delta", "/echo"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7)
    end,
    scenario("status-200,403", tree, Set{"/alpha", "/charlie"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7, rules: status_rules("200,403"))
    end,
    scenario("status-range-500-599", tree, Set{"/delta"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7, rules: status_rules("500-599"))
    end,
    scenario("matcher-mode-and", tree, Set{"/alpha"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7,
        rules: J::Rules.new([J::Rule.build("status", "200"), J::Rule.build("size", "4")], matcher_mode: J::Rules::Mode::And))
    end,
  ]
end

# The size/word/line filters: match a broad set, then drop by a counted
# dimension (single value, comma list, over the raw-byte counts).
private def metric_filter_scenarios : Array(Parity::Scenario)
  [
    scenario("size-filter-3", tree, Set{"/alpha", "/bravo", "/charlie", "/echo", "/ghost"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7, rules: status_rules("all", [J::Rule.build("size", "3")]))
    end,
    scenario("size-filter-list-3,6", tree, Set{"/alpha", "/bravo", "/echo"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7, rules: status_rules(J::Rules::DEFAULT_STATUS, [J::Rule.build("size", "3,6")]))
    end,
    scenario("word-filter-2", {"/w3" => Route.new(200, "a b c"), "/w2" => Route.new(200, "a b"), "/w1" => Route.new(200, "abc")}, Set{"/w1", "/w3"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("w1", "w2", "w3", "miss"), concurrency: 4, rules: status_rules(J::Rules::DEFAULT_STATUS, [J::Rule.build("word", "2")]))
    end,
    scenario("line-filter-3", {"/l3" => Route.new(200, "a\nb\nc"), "/l1" => Route.new(200, "a")}, Set{"/l1"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("l1", "l3", "miss"), concurrency: 3, rules: status_rules(J::Rules::DEFAULT_STATUS, [J::Rule.build("line", "3")]))
    end,
  ]
end

# The regex (body and headers) and time filters, plus the and-mode filter set
# that drops only when every filter matches.
private def content_filter_scenarios : Array(Parity::Scenario)
  [
    scenario("regex-body", {"/hit" => Route.new(200, "welcome admin user"), "/nohit" => Route.new(200, "nothing to see")}, Set{"/hit"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("hit", "nohit", "miss"), concurrency: 3, rules: J::Rules.new([J::Rule.build("regex", "admin")]))
    end,
    scenario("regex-header", {"/json" => Route.new(200, "{}", content_type: "application/json"), "/html" => Route.new(200, "<p></p>")}, Set{"/json"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("json", "html", "miss"), concurrency: 3, rules: J::Rules.new([J::Rule.build("regex", "application/json")]))
    end,
    scenario("time-filter", {"/fast" => Route.new(200, "fast"), "/slow" => Route.new(200, "slow", delay: 400.milliseconds)}, Set{"/fast"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("fast", "slow"), concurrency: 2, rules: status_rules(J::Rules::DEFAULT_STATUS, [J::Rule.build("time", ">150")]))
    end,
    scenario("filter-mode-and", tree, Set{"/bravo", "/charlie", "/delta", "/echo"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), words, concurrency: 7,
        rules: J::Rules.new([J::Rule.build("status", J::Rules::DEFAULT_STATUS)], [J::Rule.build("status", "200"), J::Rule.build("size", "4")], filter_mode: J::Rules::Mode::And))
    end,
  ]
end

# The multi-wordlist input modes: clusterbomb walks every combination,
# pitchfork walks the sources in lockstep (so it reaches fewer paths).
private def input_scenarios : Array(Parity::Scenario)
  quad = {"/api/v1" => Route.new(200, "x"), "/app/v2" => Route.new(200, "x"), "/api/v2" => Route.new(200, "x"), "/app/v1" => Route.new(200, "x")}
  [
    scenario("clusterbomb", {"/api/v1" => Route.new(200, "ok"), "/api/v2" => Route.new(200, "ok")}, Set{"/api/v1", "/api/v2"}) do |b|
      input = J::Input.new([J::Source.new("FUZZ", wordlist("api", "app")), J::Source.new("FUZ2Z", wordlist("v1", "v2"))])
      J::Scan.new(J::Template.new("#{b}/FUZZ/FUZ2Z", input.keywords), input, concurrency: 4)
    end,
    scenario("pitchfork", quad, Set{"/api/v1", "/app/v2"}) do |b|
      input = J::Input.new([J::Source.new("FUZZ", wordlist("api", "app")), J::Source.new("FUZ2Z", wordlist("v1", "v2"))], J::Input::Mode::Pitchfork)
      J::Scan.new(J::Template.new("#{b}/FUZZ/FUZ2Z", input.keywords), input, concurrency: 2)
    end,
  ]
end

# Autocalibration: on a wildcard host it learns the constant shape and drops it;
# on a well-behaved 404 host it learns nothing and keeps every real hit.
private def calibration_scenarios : Array(Parity::Scenario)
  [
    scenario("autocalibration-wildcard", {"/unique" => Route.new(200, "a much longer unique body")}, Set{"/unique"}, wildcard: true) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("unique", "miss1", "miss2"), concurrency: 3, auto_calibrate: true)
    end,
    scenario("autocalibration-noop", {"/real1" => Route.new(200, "unique one here"), "/real2" => Route.new(200, "another body entirely now")}, Set{"/real1", "/real2"}) do |b|
      J::Scan.new(J::Template.new("#{b}/FUZZ"), wordlist("real1", "real2", "miss"), concurrency: 3, auto_calibrate: true)
    end,
  ]
end

describe "Jekyll parity vs the fixture" do
  it "reproduces the expected findings to >= 95% across the scenarios" do
    scenarios = status_scenarios + metric_filter_scenarios + content_filter_scenarios +
                input_scenarios + calibration_scenarios
    score = Parity.score(scenarios)
    puts "\nJekyll parity vs fixture: #{(score * 100).round(1)}% over #{scenarios.size} scenarios\n#{Parity.report(scenarios)}"
    score.should be >= 0.95
    scenarios.each(&.extra.should(be_empty)) # no false positives anywhere
  end
end
