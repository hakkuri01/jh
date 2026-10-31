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

  it "stays linear on an unterminated-quote body instead of backtracking without bound" do
    # A quoted run with no closing quote is the classic LinkFinder ReDoS shape;
    # the atomic group forbids the backtracking that would make PCRE2 superlinear.
    # A catastrophic regex would hang the suite outright, so completing at all is
    # the evidence here (no wall-clock assertion).
    extractor.extract(%("#{"/a" * 100_000}), "/").size.should be < 1000
  end

  it "caps sub-path expansion so one hugely deep link cannot blow up time or memory" do
    # A single link with thousands of segments would expand to O(segments^2)
    # parents; past the cap only the full path is kept.
    deep = "/#{(1..5_000).map { |n| "s#{n}" }.join("/")}/leaf"
    paths = extractor.extract(%(<a href="#{deep}">x</a>), "/")
    paths.size.should be <= 2 # the full path, not 5000 parent directories
  end

  it "caps how many links one hostile body can yield (bounds the work, not just the queue)" do
    # Thousands of unique links, each expanding to several sub-paths, would build
    # a multi-million-entry set; extraction stops at MAX_LINKS.
    body = String.build { |io| 3_000.times { |n| io << %(<a href="/u#{n}/a/b/c">) } }
    extractor.extract(body, "/").size.should be <= JekyllHyde::Hyde::Extractor::MAX_LINKS + 10
  end

  it "drops a single link longer than the byte cap before it reaches the wire" do
    giant = "/#{"a" * (JekyllHyde::Hyde::Extractor::MAX_LINK_BYTES + 10)}"
    extractor.extract(%(<a href="#{giant}">x</a>), "/").should be_empty
  end

  it "drops non-http(s) scheme links (mailto, javascript, tel, data) rather than requesting them as paths" do
    body = %(<a href="mailto:a@b.c">m</a><a href="javascript:void(0)">j</a>) \
           %(<a href="tel:+15550100">t</a><a href="data:text/plain,hi">d</a><a href="/real">r</a>)
    paths = extractor.extract(body, "/app/index.html")
    paths.should contain("/real")
    paths.any? { |p| {"mailto", "javascript", "tel:", "data:"}.any? { |s| p.includes?(s) } }.should be_false
  end

  it "treats a host that differs only in case as same-origin" do
    JekyllHyde::Hyde::Extractor.new("http://EXAMPLE.com").extract(%(<a href="http://example.COM/ok">), "/").should contain("/ok")
  end
end
