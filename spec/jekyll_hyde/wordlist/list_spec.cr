require "../../spec_helper"
require "../../../src/jekyll_hyde/wordlist/list"

# Writes each body to a temp file, yields the paths, and deletes them after.
private def with_lists(*bodies : String, &)
  paths = bodies.map do |body|
    file = File.tempfile("jh-wl")
    file.print(body)
    file.close
    file.path
  end
  begin
    yield paths
  ensure
    paths.each { |path| File.delete?(path) }
  end
end

private def dedup(*bodies : String) : JekyllHyde::Wordlist::List
  with_lists(*bodies) { |paths| JekyllHyde::Wordlist::List.deduplicated(paths) }
end

private def positional(*bodies : String) : JekyllHyde::Wordlist::List
  with_lists(*bodies) { |paths| JekyllHyde::Wordlist::List.positional(paths) }
end

describe JekyllHyde::Wordlist::List do
  describe ".deduplicated (Hyde)" do
    it "loads entries and reports the effective count" do
      list = dedup("admin\nlogin\napi\n")
      list.entries.should eq(["admin", "login", "api"])
      list.size.should eq(3)
      list.empty?.should be_false
    end

    it "deduplicates entries, keeping first-seen order" do
      dedup("admin\nlogin\nadmin\napi\nlogin\n").entries.should eq(["admin", "login", "api"])
    end

    it "drops blank lines and # comments" do
      dedup("# header\nadmin\n\nlogin\n").entries.should eq(["admin", "login"])
    end

    it "trims leading slashes so /admin and admin are one entry" do
      dedup("/admin\nadmin\n//double\n").entries.should eq(["admin", "double"])
    end

    it "strips a trailing carriage return from CRLF files" do
      dedup("admin\r\nlogin\r\n").entries.should eq(["admin", "login"])
    end

    it "merges multiple files, deduplicating across them" do
      list = dedup("admin\nlogin\n", "login\napi\n")
      list.entries.should eq(["admin", "login", "api"])
    end

    it "reports empty for an all-comment or blank file" do
      list = dedup("# only\n\n# more\n")
      list.empty?.should be_true
      list.size.should eq(0)
    end
  end

  describe ".positional (Jekyll)" do
    it "keeps every line in order, including duplicates" do
      positional("admin\nlogin\nadmin\n").entries.should eq(["admin", "login", "admin"])
    end

    it "keeps blank lines as empty entries" do
      positional("admin\n\nlogin\n").entries.should eq(["admin", "", "login"])
    end

    it "does not strip comments or leading slashes" do
      positional("# c\n/admin\n").entries.should eq(["# c", "/admin"])
    end

    it "strips a trailing carriage return from CRLF files" do
      positional("admin\r\nlogin\r\n").entries.should eq(["admin", "login"])
    end

    it "merges files preserving order and duplicates" do
      positional("a\nb\n", "b\nc\n").entries.should eq(["a", "b", "b", "c"])
    end
  end

  describe "#find" do
    it "finds entries case-insensitively, preserving original case" do
      list = dedup("Admin\nadministrator\nlogin\n")
      list.find("admin").should eq(["Admin", "administrator"])
      list.find("LOG").should eq(["login"])
      list.find("missing").should be_empty
    end

    it "returns an independent copy of every entry for an empty query" do
      list = dedup("a\nb\n")
      all = list.find("")
      all.should eq(["a", "b"])
      all << "c"
      list.size.should eq(2)
    end
  end
end
