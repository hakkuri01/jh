require "../../spec_helper"
require "../../../src/jekyll_hyde/jekyll/input"

private def list(*words : String) : JekyllHyde::Wordlist::List
  JekyllHyde::Wordlist::List.new(words.to_a)
end

private def source(keyword : String, *words : String) : JekyllHyde::Jekyll::Source
  JekyllHyde::Jekyll::Source.new(keyword, list(*words))
end

describe JekyllHyde::Jekyll::Input do
  it "walks a single source in order" do
    input = JekyllHyde::Jekyll::Input.new([source("FUZZ", "a", "b", "c")])
    input.total.should eq(3)
    input.to_a.should eq([{"FUZZ" => "a"}, {"FUZZ" => "b"}, {"FUZZ" => "c"}])
  end

  it "walks clusterbomb as a product, the first source varying fastest" do
    input = JekyllHyde::Jekyll::Input.new([
      source("FUZZ", "a", "b"),
      source("FUZ2Z", "x", "y", "z"),
    ])
    input.total.should eq(6)
    input.to_a.should eq([
      {"FUZZ" => "a", "FUZ2Z" => "x"},
      {"FUZZ" => "b", "FUZ2Z" => "x"},
      {"FUZZ" => "a", "FUZ2Z" => "y"},
      {"FUZZ" => "b", "FUZ2Z" => "y"},
      {"FUZZ" => "a", "FUZ2Z" => "z"},
      {"FUZZ" => "b", "FUZ2Z" => "z"},
    ])
  end

  it "walks pitchfork in lockstep, wrapping a shorter list" do
    input = JekyllHyde::Jekyll::Input.new([
      source("FUZZ", "a", "b", "c"),
      source("FUZ2Z", "x", "y"),
    ], JekyllHyde::Jekyll::Input::Mode::Pitchfork)
    input.total.should eq(3)
    input.to_a.should eq([
      {"FUZZ" => "a", "FUZ2Z" => "x"},
      {"FUZZ" => "b", "FUZ2Z" => "y"},
      {"FUZZ" => "c", "FUZ2Z" => "x"},
    ])
  end

  it "yields nothing and totals zero when a source is empty" do
    empty = JekyllHyde::Jekyll::Source.new("FUZ2Z", JekyllHyde::Wordlist::List.new([] of String))
    input = JekyllHyde::Jekyll::Input.new([source("FUZZ", "a"), empty])
    input.total.should eq(0)
    input.to_a.should be_empty
  end

  it "rejects no sources and an empty keyword" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Input.new([] of JekyllHyde::Jekyll::Source) }
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Input.new([source("", "a")]) }
  end

  it "rejects two wordlists bound to the same keyword (only one could ever take effect)" do
    expect_raises(ArgumentError, "bound to FUZZ") do
      JekyllHyde::Jekyll::Input.new([source("FUZZ", "a", "b"), source("FUZZ", "x", "y")])
    end
  end

  it "parses a mode name with the stdlib enum" do
    JekyllHyde::Jekyll::Input::Mode.parse("pitchfork").should eq(JekyllHyde::Jekyll::Input::Mode::Pitchfork)
    JekyllHyde::Jekyll::Input::Mode.parse("clusterbomb").should eq(JekyllHyde::Jekyll::Input::Mode::Clusterbomb)
  end
end
