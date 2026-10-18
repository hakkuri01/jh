require "../spec_helper"
require "../support/fixture_server"
require "../../src/jekyll_hyde/entry"

private def wordlist_file(*words : String) : String
  file = File.tempfile("jh_wl")
  words.each { |word| file.puts(word) }
  file.close
  file.path
end

describe JekyllHyde::Entry do
  it "runs a Jekyll scan, streams a hit, and prints a summary" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    io = IO::Memory.new
    begin
      code = JekyllHyde::Entry.run(["--jekyll", "-u", "#{server.base}/FUZZ", "-w", path, "-t", "4"], io)
      code.should eq(0)
      out = io.to_s
      out.should contain("/admin")    # the kept result row
      out.should contain("1 results") # the summary
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "runs a Hyde scan from the origin" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    io = IO::Memory.new
    begin
      JekyllHyde::Entry.run(["-u", server.base, "-w", path, "-t", "4"], io).should eq(0)
      io.to_s.should contain("/admin")
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "exports results to a CSV file" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin")
    outfile = File.tempfile("jh_out")
    outfile.close
    io = IO::Memory.new
    begin
      JekyllHyde::Entry.run(["--jekyll", "-u", "#{server.base}/FUZZ", "-w", path, "-o", outfile.path, "--format", "csv"], io).should eq(0)
      File.read(outfile.path).should contain("/admin")
      io.to_s.should contain("wrote 1 results")
    ensure
      server.stop
      File.delete(path)
      File.delete(outfile.path)
    end
  end

  it "errors without a target or wordlist" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["-w", "x"], io).should eq(2)
    io.to_s.should contain("target URL is required")
  end

  it "errors when Jekyll has no FUZZ keyword" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--jekyll", "-u", "http://host/", "-w", "x"], io).should eq(2)
    io.to_s.should contain("FUZZ keyword")
  end

  it "errors on an unknown option" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--bogus"], io).should eq(2)
    io.to_s.should contain("unknown option")
  end

  it "prints help and exits zero" do
    io = IO::Memory.new
    JekyllHyde::Entry.run(["--help"], io).should eq(0)
    io.to_s.should contain("usage: jh")
  end
end
