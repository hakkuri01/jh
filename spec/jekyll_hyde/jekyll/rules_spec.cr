require "../../spec_helper"
require "../../../src/jekyll_hyde/jekyll/rules"

private def candidate(status : Int32, size : Int64 = 10_i64, words : Int32 = 2, lines : Int32 = 1) : JekyllHyde::Jekyll::Candidate
  response = JekyllHyde::Core::Response.new("u", status, size, words, lines)
  JekyllHyde::Jekyll::Candidate.new(response, Bytes.empty, Time::Span.zero)
end

private def rule(name : String, value : String) : JekyllHyde::Jekyll::Rule
  JekyllHyde::Jekyll::Rule.build(name, value)
end

describe JekyllHyde::Jekyll::Rules do
  it "keeps what the default status matcher accepts" do
    rules = JekyllHyde::Jekyll::Rules.default
    rules.keep?(candidate(200)).should be_true
    rules.keep?(candidate(404)).should be_false
  end

  it "rejects everything with no matchers" do
    JekyllHyde::Jekyll::Rules.new([] of JekyllHyde::Jekyll::Rule).keep?(candidate(200)).should be_false
  end

  it "combines matchers with or (any) and and (all)" do
    or_rules = JekyllHyde::Jekyll::Rules.new([rule("status", "200"), rule("size", "99")])
    or_rules.keep?(candidate(200, size: 10_i64)).should be_true # status matches, size does not
    and_rules = JekyllHyde::Jekyll::Rules.new([rule("status", "200"), rule("size", "99")], matcher_mode: JekyllHyde::Jekyll::Rules::Mode::And)
    and_rules.keep?(candidate(200, size: 10_i64)).should be_false # size must also match
    and_rules.keep?(candidate(200, size: 99_i64)).should be_true
  end

  it "filters: or drops if any filter matches, and drops only if all match" do
    # matcher accepts all; filters decide the drop
    or_filter = JekyllHyde::Jekyll::Rules.new([rule("status", "all")], [rule("status", "404"), rule("size", "0")])
    or_filter.keep?(candidate(404, size: 10_i64)).should be_false # a 404 matches the filter -> dropped
    or_filter.keep?(candidate(200, size: 10_i64)).should be_true  # neither filter matches -> kept
    and_filter = JekyllHyde::Jekyll::Rules.new([rule("status", "all")], [rule("status", "404"), rule("size", "0")], filter_mode: JekyllHyde::Jekyll::Rules::Mode::And)
    and_filter.keep?(candidate(404, size: 10_i64)).should be_true # only status matches, not all -> kept
    and_filter.keep?(candidate(404, size: 0_i64)).should be_false # both match -> dropped
  end

  it "parses a mode name with the stdlib enum" do
    JekyllHyde::Jekyll::Rules::Mode.parse("and").should eq(JekyllHyde::Jekyll::Rules::Mode::And)
    JekyllHyde::Jekyll::Rules::Mode.parse("or").should eq(JekyllHyde::Jekyll::Rules::Mode::Or)
  end
end
