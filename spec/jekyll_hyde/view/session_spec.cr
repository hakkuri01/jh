require "../../spec_helper"
require "../../support/fixture_server"
require "../../support/wordlists"
require "../../../src/jekyll_hyde/view/session"

# A Hyde config for *url* over the single wordlist *path*.
private def hyde_config(url : String, path : String, *, concurrency = 4, depth = 4, extensions = [] of String) : JekyllHyde::ScanConfig
  config = JekyllHyde::ScanConfig.new
  config.mode = "HYDE"
  config.url = url
  config.wordlists = [path]
  config.threads = concurrency
  config.depth = depth
  config.extensions = extensions
  config
end

# A Jekyll config for a FUZZ *url* over one or more "-w" specs.
private def jekyll_config(url : String, *paths : String, concurrency = 4, matchers = [] of JekyllHyde::Jekyll::Rule) : JekyllHyde::ScanConfig
  config = JekyllHyde::ScanConfig.new
  config.mode = "JEKYLL"
  config.url = url
  config.wordlists = paths.to_a
  config.threads = concurrency
  config.matchers = matchers
  config
end

# Pump the session the way the Elm loop does, returning the terminal message.
# A tick (a frame elapsed with no hit) is ignored, as the loop would redraw and
# keep listening.
private def drain(session : JekyllHyde::View::ScanSession) : JekyllHyde::Tui::Msg
  loop do
    msg = session.listen(1.millisecond).call
    if msg.is_a?(JekyllHyde::View::ScanHitMsg)
      session.record(msg.response)
    elsif msg.is_a?(JekyllHyde::View::ScanTickMsg)
      next
    else
      return msg
    end
  end
end

describe JekyllHyde::View::ScanSession do
  it "streams each kept hit and ends with a done message" do
    server = FixtureServer.new({
      "/admin" => FixtureServer::Route.new(200, "secret"),
      "/pub"   => FixtureServer::Route.new(200, "open"),
    })
    path = wordlist_file("admin", "pub", "missing")
    begin
      session = JekyllHyde::View::ScanSession.new(hyde_config(server.base, path))
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      session.hits.map(&.url.sub(server.base, "")).to_set.should eq(Set{"/admin", "/pub"})
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "reports a failure as one line without the absolute path when the wordlist cannot be read" do
    server = FixtureServer.new({} of String => FixtureServer::Route)
    begin
      session = JekyllHyde::View::ScanSession.new(hyde_config(server.base, "/no/such/dir/secret-wordlist.txt", concurrency: 2, depth: 1))
      msg = drain(session)
      msg.should be_a(JekyllHyde::View::ScanFailedMsg)
      reason = msg.as(JekyllHyde::View::ScanFailedMsg).reason
      reason.should contain("secret-wordlist.txt")
      reason.should_not contain("/no/such/dir") # no internal path leaks on screen
      session.hits.should be_empty
    ensure
      server.stop
    end
  end

  it "fails cleanly on a malformed target instead of crashing a worker fiber" do
    path = wordlist_file("x")
    begin
      session = JekyllHyde::View::ScanSession.new(hyde_config("-u http://127.0.0.1:1", path, concurrency: 2, depth: 1))
      drain(session).should be_a(JekyllHyde::View::ScanFailedMsg)
      session.hits.should be_empty
    ensure
      File.delete(path)
    end
  end

  it "appends extensions to each requested word (-e)" do
    server = FixtureServer.new({"/admin.php" => FixtureServer::Route.new(200, "a genuinely discovered php endpoint with unique content")})
    path = wordlist_file("admin")
    begin
      session = JekyllHyde::View::ScanSession.new(hyde_config(server.base, path, concurrency: 3, depth: 1, extensions: ["php"]))
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      session.hits.map(&.url.sub(server.base, "")).should contain("/admin.php")
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "keeps only matcher-approved hits in a Jekyll run (status matcher)" do
    server = FixtureServer.new({
      "/keep" => FixtureServer::Route.new(200, "a genuinely discovered endpoint with unique content"),
      "/drop" => FixtureServer::Route.new(301, "", location: "/drop/"),
    })
    path = wordlist_file("keep", "drop")
    begin
      matchers = [JekyllHyde::Jekyll::Rule.build("status", "200")]
      session = JekyllHyde::View::ScanSession.new(jekyll_config("#{server.base}/FUZZ", path, matchers: matchers))
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      urls = session.hits.map(&.url.sub(server.base, ""))
      urls.should contain("/keep")
      urls.should_not contain("/drop")
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "walks a Jekyll clusterbomb across two keyworded wordlists" do
    server = FixtureServer.new({
      "/api/v1" => FixtureServer::Route.new(200, "x"), "/api/v2" => FixtureServer::Route.new(200, "x"),
      "/app/v1" => FixtureServer::Route.new(200, "x"), "/app/v2" => FixtureServer::Route.new(200, "x"),
    })
    verbs = wordlist_file("api", "app")
    vers = wordlist_file("v1", "v2")
    begin
      config = jekyll_config("#{server.base}/FUZZ/FUZ2Z", "#{verbs}:FUZZ", "#{vers}:FUZ2Z")
      session = JekyllHyde::View::ScanSession.new(config)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      session.hits.size.should eq(4)
    ensure
      server.stop
      File.delete(verbs)
      File.delete(vers)
    end
  end

  it "writes results to the -o path when the scan finishes" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin")
    outfile = File.tempfile("jh_out")
    outfile.close
    begin
      config = jekyll_config("#{server.base}/FUZZ", path)
      config.output = outfile.path
      config.format = "csv"
      session = JekyllHyde::View::ScanSession.new(config)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      File.read(outfile.path).should contain("/admin")
      session.warning.should be_nil
    ensure
      server.stop
      File.delete(path)
      File.delete(outfile.path)
    end
  end

  it "sends supplied headers and a cookie but never writes them into an export" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret body")})
    path = wordlist_file("admin")
    outfile = File.tempfile("jh_out")
    outfile.close
    begin
      config = jekyll_config("#{server.base}/FUZZ", path)
      config.headers = ["Authorization: Bearer LEAKTOKEN"]
      config.cookie = "session=LEAKCOOKIE"
      config.output = outfile.path
      config.format = "json"
      session = JekyllHyde::View::ScanSession.new(config)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      # the auth material went out on the wire ...
      server.received_headers.any? { |h| h["Authorization"]? == "Bearer LEAKTOKEN" }.should be_true
      server.received_headers.any? { |h| h["Cookie"]? == "session=LEAKCOOKIE" }.should be_true
      # ... but never landed in the results file
      dump = File.read(outfile.path)
      dump.should contain("/admin")
      dump.should_not contain("LEAKTOKEN")
      dump.should_not contain("LEAKCOOKIE")
    ensure
      server.stop
      File.delete(path)
      File.delete(outfile.path)
    end
  end

  it "sends a request body but never writes it into an export" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret body")})
    path = wordlist_file("admin")
    outfile = File.tempfile("jh_out")
    outfile.close
    begin
      config = jekyll_config("#{server.base}/FUZZ", path)
      config.method = "POST"
      config.body = "payload=LEAKBODY"
      config.output = outfile.path
      config.format = "json"
      session = JekyllHyde::View::ScanSession.new(config)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      server.received_bodies.any?(&.includes?("LEAKBODY")).should be_true # went out on the wire
      dump = File.read(outfile.path)
      dump.should contain("/admin")
      dump.should_not contain("LEAKBODY") # ... but never into the results file
    ensure
      server.stop
      File.delete(path)
      File.delete(outfile.path)
    end
  end

  it "sends the request body on Hyde requests too" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "x")})
    path = wordlist_file("admin")
    begin
      config = hyde_config(server.base, path, concurrency: 2, depth: 1)
      config.method = "POST"
      config.body = "probe=1"
      session = JekyllHyde::View::ScanSession.new(config)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      server.received_bodies.any?(&.==("probe=1")).should be_true
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "surfaces a failed export as a warning and leaves no partial file (not silent success)" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin")
    begin
      config = jekyll_config("#{server.base}/FUZZ", path)
      config.output = "/no/such/dir/out.json" # unwritable directory
      session = JekyllHyde::View::ScanSession.new(config)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg) # results still complete
      session.hits.map(&.url.sub(server.base, "")).should contain("/admin")
      warning = session.warning
      warning.should_not be_nil
      warning.not_nil!.should contain("out.json")
      warning.not_nil!.should_not contain("/no/such/dir")   # no internal path on screen
      File.exists?("/no/such/dir/out.json").should be_false # no partial left behind
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "ticks when a frame elapses before the next hit" do
    server = FixtureServer.new({"/x" => FixtureServer::Route.new(200, "hi")}, delay: 100.milliseconds)
    path = wordlist_file("x")
    begin
      session = JekyllHyde::View::ScanSession.new(hyde_config(server.base, path, concurrency: 2, depth: 1))
      # Every response is delayed well past the 1ms frame, so the first pull
      # times out to a tick rather than a hit.
      session.listen(1.millisecond).call.should be_a(JekyllHyde::View::ScanTickMsg)
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "cancel closes the result channel so listen resolves instead of raising into the Elm loop" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin")
    begin
      session = JekyllHyde::View::ScanSession.new(hyde_config(server.base, path, concurrency: 2, depth: 1))
      session.cancel
      # Closing the channel on cancel must not make the Elm loop's listen command
      # raise Channel::ClosedError; it resolves to an ordinary message (a tick, or
      # a hit still buffered), which the app discards for the superseded session.
      session.listen(1.millisecond).call.should be_a(JekyllHyde::Tui::Msg)
    ensure
      server.stop
      File.delete(path)
    end
  end
end
