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

  it "drops pages similar to an operator reference page (--filter-similar-to)" do
    noise = "Sorry, the page you requested could not be located on this server. " \
            "Please verify the address and try again shortly, or browse our catalogue of products and services."
    server = FixtureServer.new({
      "/missingpage" => FixtureServer::Route.new(200, noise), # the reference page
      "/alsogone"    => FixtureServer::Route.new(200, noise), # a near-duplicate of it
      "/real"        => FixtureServer::Route.new(200, "Welcome to the administrative dashboard listing user accounts, billing settings, audit logs, and deployment history."),
    })
    begin
      scan = JekyllHyde::Hyde::Scan.new(server.base, wordlist("missingpage", "alsogone", "real"), concurrency: 4, similar_to: ["#{server.base}/missingpage"])
      kept = found(scan.run, server.base).map(&.first)
      kept.should contain("/real")
      kept.should_not contain("/alsogone") # filtered as a near-duplicate of the reference
      kept.should_not contain("/missingpage")
    ensure
      server.stop
    end
  end

  it "is unaffected when the reference page cannot be fetched, and warns (best effort)" do
    server = FixtureServer.new({"/real" => FixtureServer::Route.new(200, "a genuinely unique discovered page")})
    begin
      # A valid but unreachable reference (port 1 refuses): skipped, not fatal.
      scan = JekyllHyde::Hyde::Scan.new(server.base, wordlist("real"), concurrency: 2, max_depth: 1, similar_to: ["http://127.0.0.1:1/ref"])
      found(scan.run, server.base).map(&.first).should contain("/real")
      scan.warning.should_not be_nil # the unreachable reference was skipped with a notice
    ensure
      server.stop
    end
  end

  it "recurses on a relative directory redirect (Location: admin/, not /admin/)" do
    server = FixtureServer.new({
      "/admin"        => FixtureServer::Route.new(301, "", location: "admin/"),
      "/admin/secret" => FixtureServer::Route.new(200, "the hidden admin dashboard listing accounts"),
    })
    begin
      results = JekyllHyde::Hyde::Scan.new(server.base, wordlist("admin", "secret"), concurrency: 4).run
      hits = found(results, server.base)
      hits.should contain({"/admin", 301})
      hits.should contain({"/admin/secret", 200}) # only reachable if the relative redirect was read as a directory
    ensure
      server.stop
    end
  end

  it "recurses into a directory whose own response is filtered (recurse before filter)" do
    noise = "Sorry, that page could not be found on this server; please check the address and try again later, or browse the catalogue."
    server = FixtureServer.new({
      "/app"       => FixtureServer::Route.new(301, noise, location: "/app/"), # a directory that looks like the soft 404
      "/app/admin" => FixtureServer::Route.new(200, "the internal administrative dashboard with billing and audit logs"),
    })
    begin
      scan = JekyllHyde::Hyde::Scan.new(server.base, wordlist("app", "admin"), concurrency: 4, similar_to: ["#{server.base}/app"])
      hits = found(scan.run, server.base).map(&.first)
      hits.should_not contain("/app")   # filtered as a near-duplicate of the reference
      hits.should contain("/app/admin") # but the directory was descended before the filter dropped it
    ensure
      server.stop
    end
  end

  it "scans the whole wordlist even past the discovered-link budget (the cap counts only discovered links)" do
    links = String.build { |io| 10.times { |n| io << %(<a href="/l#{n}">x</a>) } }
    server = FixtureServer.new({"/" => FixtureServer::Route.new(200, links)})
    begin
      words = (0...10).map { |n| "w#{n}" }
      scan = JekyllHyde::Hyde::Scan.new(server.base, JekyllHyde::Wordlist::List.new(words), concurrency: 4, max_depth: 1, max_frontier: 3)
      scan.run
      words.each { |word| server.received.should contain("/#{word}") } # every wordlist entry still requested
      server.received.count(&.starts_with?("/l")).should be <= 3       # discovered links stopped at the budget
      scan.warning.should_not be_nil                                   # and the cap was surfaced
    ensure
      server.stop
    end
  end

  it "percent-encodes a space in a wordlist word so the request line stays valid" do
    server = FixtureServer.new({"/new%20folder" => FixtureServer::Route.new(200, "found content here")})
    begin
      results = JekyllHyde::Hyde::Scan.new(server.base, wordlist("new folder"), concurrency: 2, max_depth: 1).run
      server.received.should contain("/new%20folder") # the space went out encoded, not raw
      server.received.should_not contain("/new folder")
      found(results, server.base).map(&.first).should contain("/new%20folder")
    ensure
      server.stop
    end
  end
end
