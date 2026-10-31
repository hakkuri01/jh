require "../spec_helper"
require "../../src/jekyll_hyde/entry"

# Parse argv and return the config, bypassing the launch (which needs a tty).
private def config_for(argv : Array(String)) : JekyllHyde::ScanConfig
  JekyllHyde::Entry.new(IO::Memory.new).parse(argv)[1]
end

# Run the front door with captured streams; returns {exit code, stdout, stderr}.
# Diagnostics go to stderr so a headless stdout stays clean data; help is
# requested output and goes to stdout.
private def run_cli(argv : Array(String)) : {Int32, String, String}
  io = IO::Memory.new
  err = IO::Memory.new
  code = JekyllHyde::Entry.run(argv, io, err)
  {code, io.to_s, err.to_s}
end

# jh parses and validates a command, then runs it headless or launches the TUI.
# These specs cover that front door: the help text, the config it builds, and
# the errors it refuses to launch on. Scan execution lives in the session, app,
# and headless specs.
describe JekyllHyde::Entry do
  it "prints help to stdout and exits zero" do
    code, out, _ = run_cli(["--help"])
    code.should eq(0)
    out.should contain("usage: jh")
  end

  it "requires a mode, since a command launches straight into the scan" do
    code, _, err = run_cli(["-u", "http://host/", "-w", "x"])
    code.should eq(2)
    err.should contain("pick a mode")
  end

  it "errors without a target" do
    code, _, err = run_cli(["--hyde", "-w", "x"])
    code.should eq(2)
    err.should contain("target URL is required")
  end

  it "errors without a wordlist" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/"])
    code.should eq(2)
    err.should contain("wordlist is required")
  end

  it "errors when Jekyll has no FUZZ keyword" do
    code, _, err = run_cli(["--jekyll", "-u", "http://host/", "-w", "x"])
    code.should eq(2)
    err.should contain("FUZZ keyword")
  end

  it "errors on an unknown option" do
    code, _, err = run_cli(["--hyde", "--bogus"])
    code.should eq(2)
    err.should contain("unknown option")
  end

  it "routes diagnostics to stderr and keeps stdout clean" do
    code, out, err = run_cli(["-u", "http://host/", "-w", "x"]) # no mode
    code.should eq(2)
    out.empty?.should be_true
    err.should contain("pick a mode")
  end

  it "rejects a Jekyll-only flag in Hyde mode" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "--mc", "200"])
    code.should eq(2)
    err.should contain("Jekyll-only")
  end

  it "rejects a Hyde-only flag in Jekyll mode" do
    code, _, err = run_cli(["--jekyll", "-u", "http://host/FUZZ", "-w", "x", "--auto-tune"])
    code.should eq(2)
    err.should contain("Hyde-only")
  end

  it "rejects an export format that is not json or csv" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "-o", "out.txt", "--format", "xml"])
    code.should eq(2)
    err.should contain("json or csv")
  end

  it "refuses to launch outside an interactive terminal" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x"]) # IO::Memory is not a tty
    code.should eq(2)
    err.should contain("interactive terminal")
  end

  it "parses a Jekyll command with a status matcher into a config" do
    config = config_for(["--jekyll", "-u", "http://host/FUZZ", "-w", "words.txt", "--mc", "200", "-t", "7"])
    config.mode.should eq("JEKYLL")
    config.url.should eq("http://host/FUZZ")
    config.wordlists.should eq(["words.txt"])
    config.threads.should eq(7)
    config.matchers.size.should eq(1)
  end

  it "parses Hyde extensions and the depth bound into a config" do
    config = config_for(["--hyde", "-u", "http://host/", "-w", "words.txt", "-e", "php,html", "-d", "2"])
    config.mode.should eq("HYDE")
    config.extensions.should eq(["php", "html"])
    config.depth.should eq(2)
  end

  it "wires -k to the insecure (skip TLS verify) switch, off by default" do
    config_for(["--hyde", "-u", "http://host/", "-w", "words.txt"]).insecure?.should be_false
    config_for(["--hyde", "-u", "http://host/", "-w", "words.txt", "-k"]).insecure?.should be_true
  end

  it "parses --headless and a repeatable --filter-similar-to into the config" do
    config = config_for(["--hyde", "-u", "http://host/", "-w", "x", "--headless", "--filter-similar-to", "http://host/404", "--filter-similar-to", "http://host/soft"])
    config.headless?.should be_true
    config.filter_similar.should eq(["http://host/404", "http://host/soft"])
  end

  it "rejects --filter-similar-to in Jekyll mode (names it Hyde-only)" do
    code, _, err = run_cli(["--jekyll", "-u", "http://host/FUZZ", "-w", "x", "--filter-similar-to", "http://host/404"])
    code.should eq(2)
    err.should contain("Hyde-only")
    err.should contain("--filter-similar-to")
  end

  it "rejects a bad export format in headless even without -o" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "--headless", "--format", "xml"])
    code.should eq(2)
    err.should contain("json or csv")
  end

  it "clamps an out-of-range thread count instead of sizing an unbounded pool" do
    config_for(["--hyde", "-u", "http://host/", "-w", "x", "-t", "9999999"]).threads.should eq(JekyllHyde::ScanConfig::MAX_THREADS)
    config_for(["--hyde", "-u", "http://host/", "-w", "x", "-t", "0"]).threads.should eq(1)
  end

  it "parses a clusterbomb of keyworded wordlists into a config" do
    config = config_for(["--jekyll", "-u", "http://host/FUZZ/FUZ2Z", "-w", "a:FUZZ", "-w", "b:FUZ2Z", "--mode", "pitchfork"])
    config.wordlists.should eq(["a:FUZZ", "b:FUZ2Z"])
    config.input_mode.should eq(JekyllHyde::Jekyll::Input::Mode::Pitchfork)
  end

  it "parses -X, repeatable -H, and -b into the config" do
    config = config_for(["--hyde", "-u", "http://host/", "-w", "x", "-X", "post", "-H", "A: 1", "-H", "B: 2", "-b", "s=1"])
    config.method.should eq("POST")
    config.headers.should eq(["A: 1", "B: 2"])
    config.cookie.should eq("s=1")
    config.request_headers.should eq(["A: 1", "B: 2", "Cookie: s=1"])
  end

  it "parses --data and implies POST when the method is still the GET default" do
    config = config_for(["--jekyll", "-u", "http://host/FUZZ", "-w", "x", "--data", "a=1"])
    config.body.should eq("a=1")
    config.method.should eq("POST")
  end

  it "keeps an explicit method when --data is given" do
    config = config_for(["--jekyll", "-u", "http://host/FUZZ", "-w", "x", "--data", "a=1", "-X", "PUT"])
    config.method.should eq("PUT")
  end

  it "accepts a Jekyll keyword that appears only in the request body" do
    code, _, err = run_cli(["--jekyll", "-u", "http://host/static", "-w", "x", "--data", "token=FUZZ"])
    code.should eq(2) # a valid command stops at the terminal gate
    err.should_not contain("FUZZ keyword")
    err.should contain("interactive terminal")
  end

  it "accepts a keyworded request method in Jekyll (method fuzzing), not rejecting it as unknown" do
    code, _, err = run_cli(["--jekyll", "-u", "http://host/static", "-w", "verbs.txt:FUZZ", "-X", "FUZZ"])
    code.should eq(2)
    err.should_not contain("method must be one of")
    err.should_not contain("FUZZ keyword")
    err.should contain("interactive terminal")
  end

  it "rejects an unknown request method" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "-X", "frob"])
    code.should eq(2)
    err.should contain("method must be one of")
  end

  it "rejects a malformed header without echoing the header line (no secret leak)" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "-H", "Authorization NOSECRETHERE"])
    code.should eq(2)
    err.should contain("Name: Value")
    err.should_not contain("NOSECRETHERE") # the operator's header value never reaches the log
  end

  it "accepts a Jekyll keyword that appears only in a header, not the URL" do
    code, _, err = run_cli(["--jekyll", "-u", "http://host/static", "-w", "x", "-H", "X-Key: FUZZ"])
    code.should eq(2) # a valid command stops at the terminal gate
    err.should_not contain("FUZZ keyword")
    err.should contain("interactive terminal")
  end

  it "refuses a non-numeric thread count instead of silently keeping the default" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "-t", "lots"])
    code.should eq(2)
    err.should contain("-t needs a whole number")
  end

  it "refuses a non-numeric recursion depth" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "-d", "deep"])
    code.should eq(2)
    err.should contain("-d needs a whole number")
  end

  it "refuses a negative recursion depth (0 is the unlimited value)" do
    code, _, err = run_cli(["--hyde", "-u", "http://host/", "-w", "x", "--depth=-1"])
    code.should eq(2)
    err.should contain("cannot be negative")
  end
end
