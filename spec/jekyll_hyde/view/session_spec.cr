require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/view/session"

private def wordlist_file(*words : String) : String
  file = File.tempfile("jh_wl")
  words.each { |word| file.puts(word) }
  file.close
  file.path
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
      session = JekyllHyde::View::ScanSession.new(server.base, path, concurrency: 4, depth: 4)
      drain(session).should be_a(JekyllHyde::View::ScanDoneMsg)
      session.hits.map(&.url.sub(server.base, "")).to_set.should eq(Set{"/admin", "/pub"})
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "reports a failure as one line when the wordlist cannot be read" do
    server = FixtureServer.new({} of String => FixtureServer::Route)
    begin
      session = JekyllHyde::View::ScanSession.new(server.base, "/no/such/wordlist.txt", concurrency: 2, depth: 1)
      drain(session).should be_a(JekyllHyde::View::ScanFailedMsg)
      session.hits.should be_empty
    ensure
      server.stop
    end
  end

  it "fails cleanly on a malformed target instead of crashing a worker fiber" do
    path = wordlist_file("x")
    begin
      session = JekyllHyde::View::ScanSession.new("-u http://127.0.0.1:1", path, concurrency: 2, depth: 1)
      drain(session).should be_a(JekyllHyde::View::ScanFailedMsg)
      session.hits.should be_empty
    ensure
      File.delete(path)
    end
  end

  it "ticks when a frame elapses before the next hit" do
    server = FixtureServer.new({"/x" => FixtureServer::Route.new(200, "hi")}, delay: 100.milliseconds)
    path = wordlist_file("x")
    begin
      session = JekyllHyde::View::ScanSession.new(server.base, path, concurrency: 2, depth: 1)
      # Every response is delayed well past the 1ms frame, so the first pull
      # times out to a tick rather than a hit.
      session.listen(1.millisecond).call.should be_a(JekyllHyde::View::ScanTickMsg)
    ensure
      server.stop
      File.delete(path)
    end
  end
end
