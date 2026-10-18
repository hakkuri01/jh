require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/http/client"

describe JekyllHyde::Http::Client do
  it "fetches a route with its status, body, and content type" do
    server = FixtureServer.new({"/ok" => FixtureServer::Route.new(200, "hello world\nfoo\n")})
    begin
      outcome = JekyllHyde::Http::Client.new(server.base).fetch("/ok")
      outcome.status.should eq(200)
      String.new(outcome.body).should eq("hello world\nfoo\n")
      outcome.content_type.should eq("text/html")
      outcome.truncated.should be_false
      outcome.headers.should contain("Content-Type: text/html")
    ensure
      server.stop
    end
  end

  it "builds each mode's request defaults" do
    JekyllHyde::Http::Options.jekyll.read_timeout.should eq(10.0)
    JekyllHyde::Http::Options.jekyll.max_body_size.should eq(5_242_880)
    JekyllHyde::Http::Options.hyde.read_timeout.should eq(7.0)
    JekyllHyde::Http::Options.hyde.max_body_size.should eq(4_194_304)
  end

  it "records a redirect without following it" do
    server = FixtureServer.new({"/old" => FixtureServer::Route.new(302, "", location: "/new")})
    begin
      outcome = JekyllHyde::Http::Client.new(server.base).fetch("/old")
      outcome.status.should eq(302)
      outcome.location.should eq("/new")
    ensure
      server.stop
    end
  end

  it "returns 404 for an unknown path" do
    server = FixtureServer.new
    begin
      JekyllHyde::Http::Client.new(server.base).fetch("/missing").status.should eq(404)
    ensure
      server.stop
    end
  end

  it "truncates a body past the cap and flags it" do
    server = FixtureServer.new({"/big" => FixtureServer::Route.new(200, "x" * 100)})
    begin
      client = JekyllHyde::Http::Client.new(server.base, JekyllHyde::Http::Options.new(max_body_size: 10))
      outcome = client.fetch("/big")
      outcome.truncated.should be_true
      outcome.body.size.should eq(10)
    ensure
      server.stop
    end
  end

  it "keeps the fixture on loopback only" do
    server = FixtureServer.new
    begin
      server.base.should start_with("http://127.0.0.1:")
    ensure
      server.stop
    end
  end
end
