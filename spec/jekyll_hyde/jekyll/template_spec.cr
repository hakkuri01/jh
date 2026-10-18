require "../../spec_helper"
require "../../../src/jekyll_hyde/jekyll/template"

describe JekyllHyde::Jekyll::Template do
  it "splits the origin and substitutes FUZZ in the path, verbatim" do
    template = JekyllHyde::Jekyll::Template.new("http://host/api/FUZZ.php")
    template.origin.should eq("http://host")
    template.path("users").should eq("/api/users.php")
    template.path("a b").should eq("/api/a b.php") # operator bytes, no encoding
  end

  it "keeps a port and substitutes FUZZ in a query" do
    template = JekyllHyde::Jekyll::Template.new("http://host:8080/search?q=FUZZ")
    template.origin.should eq("http://host:8080")
    template.path("x").should eq("/search?q=x")
  end

  it "rejects a URL without FUZZ" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Template.new("http://host/admin") }
  end

  it "rejects FUZZ in the host" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Template.new("http://FUZZ.host/") }
  end

  it "rejects a non-http scheme" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Template.new("ftp://host/FUZZ") }
  end

  it "substitutes multiple keywords in one pass" do
    template = JekyllHyde::Jekyll::Template.new("http://host/FUZZ/FUZ2Z", ["FUZZ", "FUZ2Z"])
    template.path({"FUZZ" => "api", "FUZ2Z" => "users"}).should eq("/api/users")
  end

  it "does not re-substitute a value that itself contains a keyword" do
    template = JekyllHyde::Jekyll::Template.new("http://host/FUZZ/FUZ2Z", ["FUZZ", "FUZ2Z"])
    # FUZZ's value is the literal FUZ2Z; the single pass leaves it intact
    template.path({"FUZZ" => "FUZ2Z", "FUZ2Z" => "b"}).should eq("/FUZ2Z/b")
  end

  it "rejects a keyword missing from the URL" do
    expect_raises(ArgumentError) { JekyllHyde::Jekyll::Template.new("http://host/FUZZ", ["FUZZ", "FUZ2Z"]) }
  end
end
