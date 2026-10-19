require "../spec_helper"
require "../../src/jekyll_hyde/entry"

# Parse argv and return the config, bypassing the launch (which needs a tty).
private def config_for(argv : Array(String)) : JekyllHyde::ScanConfig
  JekyllHyde::Entry.new(IO::Memory.new).parse(argv)[1]
end

# jh is always the interactive program; Entry only parses and validates a
# command, then launches the TUI. These specs cover that front door: the help
# text, the config it builds, and the errors it refuses to launch on. The actual
# scan execution lives in the session and app specs.
describe JekyllHyde::Entry do
  it "prints help and exits zero" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--help"], io).should eq(0)
    io.to_s.should contain("usage: jh")
  end

  it "requires a mode, since a command launches straight into the scan" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["-u", "http://host/", "-w", "x"], io).should eq(2)
    io.to_s.should contain("pick a mode")
  end

  it "errors without a target" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--hyde", "-w", "x"], io).should eq(2)
    io.to_s.should contain("target URL is required")
  end

  it "errors without a wordlist" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--hyde", "-u", "http://host/"], io).should eq(2)
    io.to_s.should contain("wordlist is required")
  end

  it "errors when Jekyll has no FUZZ keyword" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--jekyll", "-u", "http://host/", "-w", "x"], io).should eq(2)
    io.to_s.should contain("FUZZ keyword")
  end

  it "errors on an unknown option" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--hyde", "--bogus"], io).should eq(2)
    io.to_s.should contain("unknown option")
  end

  it "rejects a Jekyll-only flag in Hyde mode" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--hyde", "-u", "http://host/", "-w", "x", "--mc", "200"], io).should eq(2)
    io.to_s.should contain("Jekyll-only")
  end

  it "rejects a Hyde-only flag in Jekyll mode" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--jekyll", "-u", "http://host/FUZZ", "-w", "x", "--auto-tune"], io).should eq(2)
    io.to_s.should contain("Hyde-only")
  end

  it "rejects an export format that is not json or csv" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--hyde", "-u", "http://host/", "-w", "x", "-o", "out.txt", "--format", "xml"], io).should eq(2)
    io.to_s.should contain("json or csv")
  end

  it "refuses to launch outside an interactive terminal" do
    io = IO::Memory.new # an IO::Memory is not a tty
    JekyllHyde::Entry.run(["--hyde", "-u", "http://host/", "-w", "x"], io).should eq(2)
    io.to_s.should contain("interactive terminal")
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

  it "parses a clusterbomb of keyworded wordlists into a config" do
    config = config_for(["--jekyll", "-u", "http://host/FUZZ/FUZ2Z", "-w", "a:FUZZ", "-w", "b:FUZ2Z", "--mode", "pitchfork"])
    config.wordlists.should eq(["a:FUZZ", "b:FUZ2Z"])
    config.input_mode.should eq(JekyllHyde::Jekyll::Input::Mode::Pitchfork)
  end
end
