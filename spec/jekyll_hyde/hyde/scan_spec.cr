require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/hyde/scan"

private def wordlist(*words : String) : JekyllHyde::Wordlist::List
  JekyllHyde::Wordlist::List.new(words.to_a)
end

# The {path, status} of each kept result, origin stripped.
private def found(results : JekyllHyde::Core::Results, origin : String)
  results.entries.map { |result| {result.url.sub(origin, ""), result.status} }.to_set
end

describe JekyllHyde::Hyde::Scan do
  it "recurses into a discovered directory and drops 404-like responses" do
    server = FixtureServer.new({
      "/admin"    => FixtureServer::Route.new(200, "secret"),
      "/sub"      => FixtureServer::Route.new(301, "", location: "/sub/"),
      "/sub/deep" => FixtureServer::Route.new(200, "nested content here"),
    })
    begin
      results = JekyllHyde::Hyde::Scan.new(server.base, wordlist("admin", "sub", "deep"), concurrency: 4).run
      hits = found(results, server.base)
      hits.should contain({"/admin", 200})
      hits.should contain({"/sub", 301})
      hits.should contain({"/sub/deep", 200})
      results.size.should eq(3)
    ensure
      server.stop
    end
  end

  it "stops recursing at the depth bound" do
    server = FixtureServer.new({
      "/a"     => FixtureServer::Route.new(301, "", location: "/a/"),
      "/a/sub" => FixtureServer::Route.new(200, "deep"),
    })
    begin
      results = JekyllHyde::Hyde::Scan.new(server.base, wordlist("a", "sub"), concurrency: 4, max_depth: 1).run
      hits = found(results, server.base)
      hits.should contain({"/a", 301})
      hits.map(&.first).should_not contain("/a/sub")
    ensure
      server.stop
    end
  end

  it "follows an extracted link into a directory the wordlist never names" do
    server = FixtureServer.new({
      "/start"       => FixtureServer::Route.new(200, %(<a href="/area/">go</a>)),
      "/area"        => FixtureServer::Route.new(301, "", location: "/area/"),
      "/area/secret" => FixtureServer::Route.new(200, "the secret dashboard internals listing"),
    })
    begin
      results = JekyllHyde::Hyde::Scan.new(server.base, wordlist("start", "secret"), concurrency: 4).run
      hits = found(results, server.base)
      hits.should contain({"/start", 200})
      hits.should contain({"/area", 301})        # discovered only via the link in /start
      hits.should contain({"/area/secret", 200}) # reachable only after /area/ was found
    ensure
      server.stop
    end
  end

  it "scans beneath a target subpath, requesting it on the wire (not resetting to root)" do
    server = FixtureServer.new({
      "/app/"      => FixtureServer::Route.new(200, "app home"),
      "/app/admin" => FixtureServer::Route.new(200, "app admin panel"),
      "/admin"     => FixtureServer::Route.new(200, "ROOT admin, out of scope"),
    })
    begin
      results = JekyllHyde::Hyde::Scan.new("#{server.base}/app", wordlist("admin"), concurrency: 4).run
      hits = found(results, server.base)
      hits.should contain({"/app/admin", 200})
      hits.map(&.first).should_not contain("/admin") # root was never in scope
      # The subpath was actually requested, not just relabeled.
      server.received.should contain("/app/admin")
      server.received.should_not contain("/admin")
    ensure
      server.stop
    end
  end

  it "stops a hostile fresh-link chain at the frontier cap" do
    # Every numeric path returns a distinct body linking to the next number, an
    # endless same-origin chain. The frontier cap, not the target, ends the walk.
    server = FixtureServer.new(responder: ->(path : String) {
      num = path.lstrip('/').to_i?
      num ? FixtureServer::Route.new(200, %(<a href="/#{num + 1}">next</a> unique body #{num})) : nil
    })
    begin
      scan = JekyllHyde::Hyde::Scan.new(server.base, wordlist("0"), concurrency: 4, max_frontier: 40)
      results = scan.run
      scan.completed.should be <= 60 # bounded: the cap plus one in-flight pool, not unbounded
      scan.warning.should_not be_nil
      results.size.should be <= 60
    ensure
      server.stop
    end
  end
end
