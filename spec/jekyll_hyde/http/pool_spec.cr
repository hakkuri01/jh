require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/http/pool"

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
end
