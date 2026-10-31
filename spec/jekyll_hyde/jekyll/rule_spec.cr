require "../../spec_helper"
require "../../../src/jekyll_hyde/jekyll/rule"

private def candidate(status : Int32 = 200, size : Int64 = 10_i64, words : Int32 = 2, lines : Int32 = 1, body : String = "", elapsed : Time::Span = Time::Span.zero, headers : String = "") : JekyllHyde::Jekyll::Candidate
  response = JekyllHyde::Core::Response.new("u", status, size, words, lines)
  JekyllHyde::Jekyll::Candidate.new(response, body.to_slice, elapsed, headers)
end

describe JekyllHyde::Jekyll::Rule do
  it "matches a status against values and ranges, with all" do
    JekyllHyde::Jekyll::Rule.build("status", "200,500-599").matches?(candidate(status: 200)).should be_true
    JekyllHyde::Jekyll::Rule.build("status", "200,500-599").matches?(candidate(status: 503)).should be_true
    JekyllHyde::Jekyll::Rule.build("status", "200,500-599").matches?(candidate(status: 301)).should be_false
    JekyllHyde::Jekyll::Rule.build("status", "all").matches?(candidate(status: 404)).should be_true
  end

  it "matches size, word, and line counts against ranges" do
    JekyllHyde::Jekyll::Rule.build("size", "10").matches?(candidate(size: 10_i64)).should be_true
    JekyllHyde::Jekyll::Rule.build("size", "0-5").matches?(candidate(size: 10_i64)).should be_false
    JekyllHyde::Jekyll::Rule.build("word", "2,4").matches?(candidate(words: 2)).should be_true
    JekyllHyde::Jekyll::Rule.build("line", "5-9").matches?(candidate(lines: 7)).should be_true
    JekyllHyde::Jekyll::Rule.build("line", "5-9").matches?(candidate(lines: 1)).should be_false
  end

  it "matches a regex against the body" do
    JekyllHyde::Jekyll::Rule.build("regex", "admin|root").matches?(candidate(body: "welcome admin")).should be_true
    JekyllHyde::Jekyll::Rule.build("regex", "admin|root").matches?(candidate(body: "nothing here")).should be_false
  end

  it "matches a regex against the response headers, not just the body" do
    headers = "Server: nginx\r\nX-Powered-By: PHP/8.1\r\n"
    JekyllHyde::Jekyll::Rule.build("regex", "Server: nginx").matches?(candidate(headers: headers)).should be_true
    JekyllHyde::Jekyll::Rule.build("regex", "PHP/8").matches?(candidate(headers: headers)).should be_true
    JekyllHyde::Jekyll::Rule.build("regex", "Tomcat").matches?(candidate(headers: headers)).should be_false
  end

  it "does not raise on a response header carrying a non-UTF-8 byte (scrubs first)" do
    # A hostile server can put a raw 0x80..0xFF byte in a header value; PCRE2
    # raises on an invalid-UTF-8 subject, which would abort a --mr/--fr scan. The
    # rule scrubs the headers and body together, so one bad byte is harmless.
    bad = String.new(Bytes[0x58, 0x3A, 0x20, 0xFF, 0x0D, 0x0A]) # "X: \xFF\r\n", invalid UTF-8
    JekyllHyde::Jekyll::Rule.build("regex", "X:").matches?(candidate(headers: bad)).should be_true
    JekyllHyde::Jekyll::Rule.build("regex", "absent").matches?(candidate(headers: bad)).should be_false
  end

  it "matches a request duration above or below a threshold in ms" do
    slow = candidate(elapsed: 200.milliseconds)
    JekyllHyde::Jekyll::Rule.build("time", ">100").matches?(slow).should be_true
    JekyllHyde::Jekyll::Rule.build("time", "<100").matches?(slow).should be_false
  end

  it "rejects malformed rule values and unknown names" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Rule.build("status", "200,nope") }
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Rule.build("regex", "(") }
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Rule.build("time", "100") }
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Rule.build("bogus", "x") }
  end
end
