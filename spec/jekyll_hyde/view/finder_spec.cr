require "../../spec_helper"
require "../../support/wordlists"
require "../../../src/jekyll_hyde/view/finder"

describe JekyllHyde::View::Finder::Session do
  it "loads every entry and filters live by case-insensitive substring" do
    path = wordlist_file("admin", "Administrator", "api", "login")
    begin
      session = JekyllHyde::View::Finder::Session.new(path, "JEKYLL")
      session.total.should eq(4)
      session.matches.size.should eq(4) # empty query shows all
      session.handle("a", 10)
      session.query.should eq("a")
      session.matches.should eq(["admin", "Administrator", "api"]) # case-insensitive substring
      session.handle("d", 10)                                      # now "ad"
      session.matches.should eq(["admin", "Administrator"])
      session.handle("backspace", 10) # back to "a"
      session.matches.size.should eq(3)
    ensure
      File.delete(path)
    end
  end

  it "closes on esc or enter and stays on any other key" do
    path = wordlist_file("x")
    begin
      session = JekyllHyde::View::Finder::Session.new(path, "HYDE")
      session.handle("esc", 10).should eq(JekyllHyde::View::Finder::Session::Action::Close)
      session.handle("enter", 10).should eq(JekyllHyde::View::Finder::Session::Action::Close)
      session.handle("z", 10).should eq(JekyllHyde::View::Finder::Session::Action::Stay)
    ensure
      File.delete(path)
    end
  end

  it "holds an unreadable file as a one-line error without the directory, not a raise" do
    session = JekyllHyde::View::Finder::Session.new("/no/such/dir/words.txt", "HYDE")
    error = session.error
    error.should_not be_nil
    error.not_nil!.should contain("words.txt")
    error.not_nil!.should_not contain("/no/such/dir")
    session.matches.should be_empty
    session.total.should eq(0)
  end

  it "clamps the scroll to the matches that overflow the visible capacity" do
    path = wordlist_file("a1", "a2", "a3", "a4", "a5")
    begin
      session = JekyllHyde::View::Finder::Session.new(path, "HYDE")
      # capacity 2: five matches leave at most (5 - 2) = 3 rows of scroll
      session.handle("end", 2)
      session.scroll.should eq(3)
      session.handle("home", 2)
      session.scroll.should eq(0)
      session.handle("pgdown", 2)
      session.scroll.should eq(2)
    ensure
      File.delete(path)
    end
  end
end
