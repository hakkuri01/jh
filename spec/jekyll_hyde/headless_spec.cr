require "../spec_helper"
require "../support/fixture_server"
require "../support/wordlists"
require "../../src/jekyll_hyde/headless"
require "../../src/jekyll_hyde/entry"
require "base64"

private def hyde_config(url : String, path : String) : JekyllHyde::ScanConfig
  config = JekyllHyde::ScanConfig.new
  config.mode = "HYDE"
  config.url = url
  config.wordlists = [path]
  config.threads = 4
  config.depth = 1
  config
end

private def jekyll_config(url : String, path : String) : JekyllHyde::ScanConfig
  config = JekyllHyde::ScanConfig.new
  config.mode = "JEKYLL"
  config.url = url
  config.wordlists = [path]
  config.threads = 4
  config
end

describe JekyllHyde::Headless do
  it "writes JSON results to stdout and progress to stderr when no -o is given" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    begin
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(hyde_config(server.base, path), sink, log).should eq(0)
      sink.to_s.should contain("/admin")           # clean data on stdout
      JSON.parse(sink.to_s).as_a.size.should eq(1) # valid JSON array of the one hit
      log.to_s.should contain("/admin")            # progress on stderr
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "writes to the -o file (CSV), keeps stdout empty, and logs a summary to stderr" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin")
    dest = File.tempfile("jh_out")
    dest.close
    begin
      config = hyde_config(server.base, path)
      config.output = dest.path
      config.format = "csv"
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(config, sink, log).should eq(0)
      File.read(dest.path).should contain("/admin")
      sink.to_s.empty?.should be_true  # no data on stdout when writing a file
      log.to_s.should contain("wrote") # summary on stderr
    ensure
      server.stop
      File.delete(path)
      File.delete(dest.path)
    end
  end

  it "fails with exit 1 and a clean stderr line on an unreadable wordlist" do
    server = FixtureServer.new({} of String => FixtureServer::Route)
    begin
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(hyde_config(server.base, "/no/such/dir/missing.txt"), sink, log).should eq(1)
      log.to_s.should contain("could not read wordlist")
      log.to_s.should_not contain("/no/such/dir") # no internal path leaks
      sink.to_s.empty?.should be_true
    ensure
      server.stop
    end
  end

  it "fails with exit 1 on a malformed target" do
    path = wordlist_file("x")
    begin
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(hyde_config("ftp://host", path), sink, log).should eq(1)
      log.to_s.should contain("not a valid URL")
    ensure
      File.delete(path)
    end
  end

  it "exits 1 when every request fails against a valid but unreachable target" do
    path = wordlist_file("a", "b")
    begin
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(hyde_config("http://127.0.0.1:1", path), sink, log).should eq(1)
      log.to_s.should contain("every request failed")
    ensure
      File.delete(path)
    end
  end

  it "runs a Jekyll scan headless, data to stdout" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    begin
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(jekyll_config("#{server.base}/FUZZ", path), sink, log).should eq(0)
      sink.to_s.should contain("/admin")
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "applies --filter-similar-to through the headless/ScanBuilder path" do
    noise = "Sorry, the page you requested could not be located on this server. " \
            "Please verify the address and try again shortly, or browse our catalogue."
    server = FixtureServer.new({
      "/ref"  => FixtureServer::Route.new(200, noise),
      "/dup"  => FixtureServer::Route.new(200, noise),
      "/real" => FixtureServer::Route.new(200, "Welcome to the administrative dashboard with user accounts, billing, and audit logs."),
    })
    path = wordlist_file("ref", "dup", "real")
    begin
      config = hyde_config(server.base, path)
      config.filter_similar = ["#{server.base}/ref"]
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(config, sink, log).should eq(0)
      sink.to_s.should contain("/real")
      sink.to_s.should_not contain("/dup") # filtered via the config -> ScanBuilder -> Hyde pass-through
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "sends URL userinfo as HTTP Basic auth (ffuf/feroxbuster parity) and never into results" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin")
    begin
      config = hyde_config(server.base.sub("http://", "http://user:pass@"), path)
      sink = IO::Memory.new
      log = IO::Memory.new
      JekyllHyde::Headless.run(config, sink, log).should eq(0)
      token = "Basic #{Base64.strict_encode("user:pass")}"
      server.received_headers.any? { |h| h["Authorization"]? == token }.should be_true # credentials sent
      sink.to_s.should_not contain("user:pass")                                        # but not exported
    ensure
      server.stop
      File.delete(path)
    end
  end
end

describe "jh --headless via Entry" do
  it "runs without a terminal and puts clean data on stdout" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    begin
      sink = IO::Memory.new # not a tty
      log = IO::Memory.new
      code = JekyllHyde::Entry.run(["--headless", "--hyde", "-u", server.base, "-w", path], sink, log)
      code.should eq(0)
      sink.to_s.should contain("/admin")                   # it ran with no terminal
      sink.to_s.should_not contain("interactive terminal") # and never hit the tty gate
    ensure
      server.stop
      File.delete(path)
    end
  end
end
