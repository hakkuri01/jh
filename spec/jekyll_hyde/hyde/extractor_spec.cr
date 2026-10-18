require "../../spec_helper"
require "../../../src/jekyll_hyde/hyde/extractor"

private ORIGIN = "http://127.0.0.1:8080"

private def extractor : JekyllHyde::Hyde::Extractor
  JekyllHyde::Hyde::Extractor.new(ORIGIN)
end

describe JekyllHyde::Hyde::Extractor do
  it "extracts in-scope paths from href/src/action attributes, with sub-paths" do
    body = %(<a href="/a/b/page.html">x</a><link href="/css/app.css"><script src="assets/main.js">)
    paths = extractor.extract(body, "/")
    paths.should contain("/a/b/page.html")
    paths.should contain("/a/b/")
    paths.should contain("/a/")
    paths.should contain("/css/app.css")
    paths.should contain("/css/")
    paths.should contain("/assets/main.js")
    paths.should contain("/assets/")
  end

  it "resolves a relative link against the response path" do
    paths = extractor.extract(%(<a href="page2.html">), "/dir/index.html")
    paths.should contain("/dir/page2.html")
    paths.should contain("/dir/")
  end

  it "folds ../ out of a relative link" do
    paths = extractor.extract(%(<a href="../up.html">), "/dir/sub/index.html")
    paths.should contain("/dir/up.html")
  end

  it "drops out-of-scope absolute urls and keeps same-origin ones" do
    body = %(<a href="http://evil.com/x"><a href="http://127.0.0.1:8080/ok">)
    paths = extractor.extract(body, "/")
    paths.any?(&.includes?("evil")).should be_false
    paths.should contain("/ok")
  end

  it "extracts allow/disallow paths from robots.txt, ignoring comments and blanks" do
    body = "User-agent: *\nDisallow: /admin/\nAllow: /public/page.html\nDisallow:\n# note\n"
    paths = extractor.extract_robots(body)
    paths.should contain("/admin")
    paths.should contain("/public/page.html")
    paths.should contain("/public/")
  end

  it "extracts endpoints embedded in javascript" do
    body = %(var api = "/api/v1/users"; fetch('/data.json'); load("assets/app.min.js");)
    paths = extractor.extract(body, "/")
    paths.should contain("/api/v1/users")
    paths.should contain("/api/v1/")
    paths.should contain("/api/")
    paths.should contain("/data.json")
    paths.should contain("/assets/app.min.js")
    paths.should contain("/assets/")
  end
end
