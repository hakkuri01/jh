require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/http/pool"

# An input stream that yields one request and then fails, standing in for a
# producer that raises partway (e.g. a FUZZ value that makes an invalid header).
private struct RaisingRequests
  include Enumerable(JekyllHyde::Http::Request)

  def each(& : JekyllHyde::Http::Request ->) : Nil
    yield JekyllHyde::Http::Request.new("GET", "/a", HTTP::Headers.new)
    raise "request generation failed"
  end
end

describe JekyllHyde::Http::Pool do
  it "runs every path and returns one result each, carrying its path" do
    server = FixtureServer.new({
      "/a" => FixtureServer::Route.new(200, "a"),
      "/b" => FixtureServer::Route.new(301, "", location: "/c"),
    })
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 2)
      jobs = {} of String => JekyllHyde::Http::Job
      pool.run(["/a", "/b", "/missing"]) { |job| jobs[job.path] = job }
      jobs.size.should eq(3)
      jobs["/a"].outcome.not_nil!.status.should eq(200)
      jobs["/b"].outcome.not_nil!.location.should eq("/c")
      jobs["/missing"].outcome.not_nil!.status.should eq(404)
    ensure
      server.stop
    end
  end

  it "caps requests in flight at the concurrency" do
    routes = {} of String => FixtureServer::Route
    12.times { |i| routes["/p#{i}"] = FixtureServer::Route.new(200, "x", delay: 10.milliseconds) }
    server = FixtureServer.new(routes)
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 4)
      count = 0
      pool.run((0...12).map { |i| "/p#{i}" }) { count += 1 }
      count.should eq(12)
      server.max_in_flight.should be <= 4
      server.max_in_flight.should be >= 2
    ensure
      server.stop
    end
  end

  it "honors a live concurrency limit below the worker ceiling" do
    routes = {} of String => FixtureServer::Route
    12.times { |i| routes["/p#{i}"] = FixtureServer::Route.new(200, "x", delay: 10.milliseconds) }
    server = FixtureServer.new(routes)
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 8)
      count = 0
      pool.run((0...12).map { |i| "/p#{i}" }, limit: -> { 2 }) { count += 1 }
      count.should eq(12)                 # every request still ran
      server.max_in_flight.should be <= 2 # but never more than the live limit at once
    ensure
      server.stop
    end
  end

  it "stops feeding new paths once cancel returns true" do
    routes = {} of String => FixtureServer::Route
    4.times { |i| routes["/p#{i}"] = FixtureServer::Route.new(200, "x") }
    server = FixtureServer.new(routes)
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 2)
      count = 0
      pool.run((0...4).map { |i| "/p#{i}" }, -> { true }) { count += 1 }
      count.should eq(0)
    ensure
      server.stop
    end
  end

  it "holds new requests while paused, then resumes to completion" do
    routes = {} of String => FixtureServer::Route
    4.times { |i| routes["/p#{i}"] = FixtureServer::Route.new(200, "x") }
    server = FixtureServer.new(routes)
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 2)
      paused = true
      spawn do
        sleep 60.milliseconds
        paused = false # resume from another fiber
      end
      count = 0
      pool.run((0...4).map { |i| "/p#{i}" }, pause: -> { paused }) { count += 1 }
      count.should eq(4) # nothing is lost; the paused feed resumed and finished
    ensure
      server.stop
    end
  end

  it "turns a malformed origin into errored jobs instead of crashing a worker" do
    pool = JekyllHyde::Http::Pool.new("-u http://127.0.0.1:1", concurrency: 2)
    jobs = [] of JekyllHyde::Http::Job
    pool.run(["/a", "/b"]) { |job| jobs << job }
    jobs.size.should eq(2)
    jobs.all?(&.outcome.nil?).should be_true
  end

  it "does not hang when request generation raises partway, and re-raises it" do
    server = FixtureServer.new({"/a" => FixtureServer::Route.new(200, "ok")})
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 2)
      # If the producer's exception left the jobs channel open, the workers would
      # block forever and this example would time out rather than raise.
      expect_raises(Exception, "request generation failed") do
        pool.run(RaisingRequests.new) { }
      end
    ensure
      server.stop
    end
  end

  it "drains in-flight workers and returns when the consumer stops early on cancel" do
    routes = {} of String => FixtureServer::Route
    8.times { |i| routes["/p#{i}"] = FixtureServer::Route.new(200, "x", delay: 20.milliseconds) }
    server = FixtureServer.new(routes)
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 4)
      cancelled = false
      seen = 0
      # The consumer takes its first result, then (as the TUI does on q) cancels
      # and raises as if its downstream channel had closed. Reaching the line
      # after run proves the pool wound its feed and workers down instead of
      # leaving four fibers and sockets parked for the process lifetime; a leak
      # would hang here, and a wrong re-raise would escape run.
      pool.run((0...8).map { |i| "/p#{i}" }, cancel: -> { cancelled }) do |_job|
        seen += 1
        cancelled = true
        raise Channel::ClosedError.new
      end
      seen.should eq(1)
    ensure
      server.stop
    end
  end

  it "re-raises a consumer error that was not a cancel, after draining the workers" do
    routes = {} of String => FixtureServer::Route
    6.times { |i| routes["/p#{i}"] = FixtureServer::Route.new(200, "x", delay: 10.milliseconds) }
    server = FixtureServer.new(routes)
    begin
      pool = JekyllHyde::Http::Pool.new(server.base, concurrency: 3)
      # No cancel proc: a consumer that raises is a real bug, surfaced after the
      # in-flight workers drain (run returns via the raise, never a hang).
      expect_raises(Exception, "consumer boom") do
        pool.run((0...6).map { |i| "/p#{i}" }) { |_job| raise "consumer boom" }
      end
    ensure
      server.stop
    end
  end
end
