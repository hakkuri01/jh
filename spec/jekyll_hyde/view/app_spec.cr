require "../../spec_helper"
require "../../support/fixture_server"
require "../../../src/jekyll_hyde/view/app"

# The top-left corner glyph and color of the app's current frame, which carries
# the active mode's accent.
private def corner(app : JekyllHyde::View::App) : JekyllHyde::Render::Cell
  app.view(100, 40).cells[0][0]
end

# The frame's rows as plain text, so a composed line can be matched by substring.
private def lines(app : JekyllHyde::View::App) : Array(String)
  app.view(100, 40).cells.map { |line| String.build { |io| line.each { |cell| io << cell[0] } } }
end

# Whether any row of the current frame contains *text*.
private def shows?(app : JekyllHyde::View::App, text : String) : Bool
  lines(app).any?(&.includes?(text))
end

# Whether any row of the frame rendered at *height* contains *text* (the scan
# dashboard's capacity, and so its scrolling, depends on the terminal height).
private def shows_at?(app : JekyllHyde::View::App, text : String, height : Int32) : Bool
  app.view(100, height).cells.map { |line| String.build { |io| line.each { |cell| io << cell[0] } } }.any?(&.includes?(text))
end

# Whether any cell of the current frame carries a background wash.
private def washed?(app : JekyllHyde::View::App) : Bool
  app.view(100, 40).cells.any? { |line| line.any? { |cell| !cell[2].nil? } }
end

# A fresh app with the boot settled into the held opener frame.
private def held : JekyllHyde::View::App
  app = JekyllHyde::View::App.new(false)
  app.update(JekyllHyde::Tui::TickMsg.new(Time.instant + 5.seconds))
  app
end

# A wordlist file holding *words*, one per line.
private def wordlist_file(*words : String) : String
  file = File.tempfile("jh_wl")
  words.each { |word| file.puts(word) }
  file.close
  file.path
end

# Focus the cockpit field at *index* from any field (k clamps to the top).
private def focus(app : JekyllHyde::View::App, index : Int32) : Nil
  10.times { app.update(JekyllHyde::Tui::KeyMsg.new("k")) }
  index.times { app.update(JekyllHyde::Tui::KeyMsg.new("j")) }
end

# Type *text* into the cockpit field at *index*, returning to NORMAL.
private def type_field(app : JekyllHyde::View::App, index : Int32, text : String) : Nil
  focus(app, index)
  app.update(JekyllHyde::Tui::KeyMsg.new("i"))
  text.each_char { |char| app.update(JekyllHyde::Tui::KeyMsg.new(char.to_s)) }
  app.update(JekyllHyde::Tui::KeyMsg.new("esc"))
end

# Drive commands the way the program loop does, until the model stops returning
# one (the scan reached its done message).
private def pump(app : JekyllHyde::View::App, command : JekyllHyde::Tui::Cmd?) : Nil
  while command
    _, command = app.update(command.call)
  end
end

describe JekyllHyde::View::App do
  it "starts an animation on init" do
    JekyllHyde::View::App.new(false).init.should_not be_nil
  end

  it "keeps ticking while the boot sequence runs" do
    app = JekyllHyde::View::App.new(false)
    _, command = app.update(JekyllHyde::Tui::TickMsg.new(Time.instant))
    command.should_not be_nil
  end

  it "opens the h reference, flips the mode panel on Tab, and steps back on q" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit
    app.update(JekyllHyde::Tui::KeyMsg.new("h"))     # open the reference
    shows?(app, "COMMAND REFERENCE").should be_true
    shows?(app, "FLAGS").should be_true
    shows?(app, "recursion · calibration · link scrape").should be_true # the Hyde panel
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("tab"))
    command.should_not be_nil # the switch animation plays from the help page
    app.update(JekyllHyde::Tui::TickMsg.new(Time.instant + 5.seconds))
    shows?(app, "COMMAND REFERENCE").should be_true                 # still on the reference
    shows?(app, "injection keyword, required in -u").should be_true # now the Jekyll panel
    app.update(JekyllHyde::Tui::KeyMsg.new("esc"))                  # esc is inert here (cheatsheet says h/q)
    shows?(app, "COMMAND REFERENCE").should be_true                 # still on the reference
    app.update(JekyllHyde::Tui::KeyMsg.new("q"))                    # steps back, does not quit
    shows?(app, "jh --jekyll").should be_true
  end

  it "launches a Jekyll scan from a FUZZ target and streams a hit" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    begin
      app = held
      app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit
      app.update(JekyllHyde::Tui::KeyMsg.new("tab"))   # switch to Jekyll
      app.update(JekyllHyde::Tui::TickMsg.new(Time.instant + 5.seconds))
      type_field(app, 0, "#{server.base}/FUZZ")
      type_field(app, 1, path)
      _, command = app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
      command.should_not be_nil
      shows?(app, "SCANNING").should be_true
      pump(app, command)
      shows?(app, "/admin").should be_true
      shows?(app, "COMPLETE").should be_true
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "launches straight onto the dashboard from a command-line scan, q drops to the cockpit" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    begin
      config = JekyllHyde::ScanConfig.new
      config.mode = "HYDE"
      config.url = server.base
      config.wordlists = [path]
      config.threads = 4
      app = JekyllHyde::View::App.new(false, config)
      command = app.init # the power-user override builds the session and opens on the scan
      command.should_not be_nil
      shows?(app, "SCANNING").should be_true   # no opener, no form
      shows?(app, "jh --hyde").should be_false # the cockpit was skipped
      pump(app, command)
      shows?(app, "/admin").should be_true
      shows?(app, "COMPLETE").should be_true
      app.update(JekyllHyde::Tui::KeyMsg.new("q")) # q drops to the cockpit to compose another
      shows?(app, "jh --hyde").should be_true
      _, quit = app.update(JekyllHyde::Tui::KeyMsg.new("q")) # a second q quits
      quit.try(&.call).should be_a(JekyllHyde::Tui::QuitMsg)
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "quits on q from the held frame" do
    app = held
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("q"))
    command.should_not be_nil
    command.try(&.call).should be_a(JekyllHyde::Tui::QuitMsg)
  end

  it "composes on the first key from the opener" do
    app = JekyllHyde::View::App.new(false)
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("x"))
    command.should be_nil
    shows?(app, "jh --hyde").should be_true
    corner(app).should eq({'┏', JekyllHyde::Render::HYDE, nil})
  end

  it "settles the boot into the held frame on its own" do
    app = JekyllHyde::View::App.new(false)
    _, command = app.update(JekyllHyde::Tui::TickMsg.new(Time.instant + 5.seconds))
    command.should be_nil
    shows?(app, "jh --hyde").should be_false
    shows?(app, "compose").should be_true
  end

  it "switches to Jekyll on Tab from the held frame" do
    app = held
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("tab"))
    command.should_not be_nil
    app.update(JekyllHyde::Tui::TickMsg.new(Time.instant + 5.seconds))
    corner(app).should eq({'┏', JekyllHyde::Render::JEKYLL, nil})
  end

  it "opens the cockpit in NORMAL and shows the Hyde command skeleton" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    shows?(app, "jh --hyde").should be_true
    shows?(app, "NORMAL").should be_true
  end

  it "composes recursion depth in Hyde but drops it in Jekyll" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    shows?(app, "-d 4").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("tab"))
    shows?(app, "-d").should be_false
    shows?(app, "jh --jekyll").should be_true
  end

  it "edits the focused field in INSERT, with Backspace" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    app.update(JekyllHyde::Tui::KeyMsg.new("i"))
    shows?(app, "INSERT").should be_true
    "api".each_char { |char| app.update(JekyllHyde::Tui::KeyMsg.new(char.to_s)) }
    shows?(app, "-u api").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("backspace"))
    shows?(app, "-u ap").should be_true
  end

  it "moves the caret with the arrows and Home/End to edit mid-field in INSERT" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    app.update(JekyllHyde::Tui::KeyMsg.new("i"))
    "abc".each_char { |char| app.update(JekyllHyde::Tui::KeyMsg.new(char.to_s)) }
    app.update(JekyllHyde::Tui::KeyMsg.new("left"))
    app.update(JekyllHyde::Tui::KeyMsg.new("X")) # insert before the last char
    shows?(app, "-u abXc").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("home"))
    app.update(JekyllHyde::Tui::KeyMsg.new("Z")) # prepend at the start
    shows?(app, "-u ZabXc").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("backspace")) # removes Z before the caret
    shows?(app, "-u abXc").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("delete")) # removes the char at the caret
    shows?(app, "-u bXc").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("end"))
    app.update(JekyllHyde::Tui::KeyMsg.new("Q")) # append at the end
    shows?(app, "-u bXcQ").should be_true
  end

  it "navigates to another field with j, then edits it" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    app.update(JekyllHyde::Tui::KeyMsg.new("j"))
    app.update(JekyllHyde::Tui::KeyMsg.new("i"))
    "wl".each_char { |char| app.update(JekyllHyde::Tui::KeyMsg.new(char.to_s)) }
    shows?(app, "-w wl").should be_true
  end

  it "leaves INSERT for NORMAL on Esc, while Enter stays in INSERT" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    app.update(JekyllHyde::Tui::KeyMsg.new("i"))
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    shows?(app, "INSERT").should be_true
    app.update(JekyllHyde::Tui::KeyMsg.new("esc"))
    shows?(app, "NORMAL").should be_true
    shows?(app, "jh --hyde").should be_true
  end

  it "quits on q from the cockpit, and Esc there is inert (no accidental quit)" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit (NORMAL)
    _, inert = app.update(JekyllHyde::Tui::KeyMsg.new("esc"))
    inert.should be_nil                     # Esc in NORMAL does nothing
    shows?(app, "jh --hyde").should be_true # still in the cockpit
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("q"))
    command.should_not be_nil
    command.try(&.call).should be_a(JekyllHyde::Tui::QuitMsg)
  end

  it "swaps the engine and resets the form on Tab" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    app.update(JekyllHyde::Tui::KeyMsg.new("i"))
    "zzz".each_char { |char| app.update(JekyllHyde::Tui::KeyMsg.new(char.to_s)) }
    app.update(JekyllHyde::Tui::KeyMsg.new("esc"))
    app.update(JekyllHyde::Tui::KeyMsg.new("tab"))
    shows?(app, "zzz").should be_false
    shows?(app, "jh --jekyll").should be_true
    shows?(app, "https://target/FUZZ").should be_true
  end

  it "shows the hold cheatsheet from the held frame on" do
    shows?(held, "compose").should be_true
  end

  it "greys the inactive mode word and accents the active one" do
    grid = held.view(100, 40)
    grid.cells[1][14][1].should eq(JekyllHyde::Render::HYDE)
    grid.cells[1][4][1].should eq(JekyllHyde::Render::MUTED)
  end

  it "washes the focused field row in the cockpit, not the hold" do
    washed?(held).should be_false
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    washed?(app).should be_true
  end

  it "always plays the static flicker on a mode switch (invariant)" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("tab"))
    command.should_not be_nil
    app.update(JekyllHyde::Tui::TickMsg.new(Time.instant + 0.25.seconds))
    glitch = JekyllHyde::Render::GLITCH
    static = app.view(100, 40).cells.sum { |line| line.count { |cell| glitch.includes?(cell[0]) } }
    static.should be > 20
  end

  it "opens the wordlist finder on / over a filled -w field and filters live" do
    path = wordlist_file("admin", "login", "administrator", "api")
    begin
      app = held
      app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit
      type_field(app, 1, path)                         # fill the wordlist field
      focus(app, 1)                                    # focus -w
      app.update(JekyllHyde::Tui::KeyMsg.new("/"))     # open the finder
      shows?(app, "FINDER").should be_true
      shows?(app, "MATCHES").should be_true
      shows?(app, "admin").should be_true
      shows?(app, "login").should be_true
      "admin".each_char { |char| app.update(JekyllHyde::Tui::KeyMsg.new(char.to_s)) }
      shows?(app, "administrator").should be_true # substring match survives
      shows?(app, "login").should be_false        # filtered out
      shows?(app, "api").should be_false
    ensure
      File.delete(path)
    end
  end

  it "steps back from the finder to the cockpit on esc, q types into the filter" do
    path = wordlist_file("alpha", "quebec")
    begin
      app = held
      app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
      type_field(app, 1, path)
      focus(app, 1)
      app.update(JekyllHyde::Tui::KeyMsg.new("/"))
      app.update(JekyllHyde::Tui::KeyMsg.new("q")) # q is a filter character, not an exit
      shows?(app, "FINDER").should be_true
      shows?(app, "quebec").should be_true # matched the q
      shows?(app, "alpha").should be_false
      app.update(JekyllHyde::Tui::KeyMsg.new("esc")) # esc returns to the form
      shows?(app, "FINDER").should be_false
      shows?(app, "jh --hyde").should be_true
    ensure
      File.delete(path)
    end
  end

  it "does not open the finder on an empty wordlist field" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    focus(app, 1)                                # -w, left empty
    app.update(JekyllHyde::Tui::KeyMsg.new("/")) # no-op
    shows?(app, "FINDER").should be_false
    shows?(app, "jh --hyde").should be_true
  end

  it "previews the wordlist with the active mode's loading discipline (Hyde dedups)" do
    path = wordlist_file("# comment", "admin", "admin", "login")
    begin
      app = held # Hyde
      app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
      type_field(app, 1, path)
      focus(app, 1)
      app.update(JekyllHyde::Tui::KeyMsg.new("/"))
      shows?(app, "FINDER").should be_true
      shows?(app, "# comment").should be_false # Hyde discipline drops comments
      shows?(app, "2 entries").should be_true  # admin (deduped once) + login
    ensure
      File.delete(path)
    end
  end

  it "does not launch a scan until the mandatory fields are set" do
    app = held
    app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit
    _, command = app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
    command.should be_nil
    shows?(app, "jh --hyde").should be_true # still composing
    shows?(app, "esc stop").should be_false # not the results view
  end

  it "launches a Hyde scan, streams a hit into the results view, and Esc returns to the cockpit" do
    server = FixtureServer.new({"/admin" => FixtureServer::Route.new(200, "secret")})
    path = wordlist_file("admin", "missing")
    begin
      app = held
      app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit
      type_field(app, 0, server.base)
      type_field(app, 1, path)
      _, command = app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
      command.should_not be_nil
      shows?(app, "SCANNING").should be_true
      pump(app, command)
      shows?(app, "/admin").should be_true
      shows?(app, "COMPLETE").should be_true
      app.update(JekyllHyde::Tui::KeyMsg.new("q")) # q steps the dashboard back to the cockpit
      shows?(app, "jh --hyde").should be_true
      _, quit = app.update(JekyllHyde::Tui::KeyMsg.new("q")) # q again quits the program
      quit.try(&.call).should be_a(JekyllHyde::Tui::QuitMsg)
    ensure
      server.stop
      File.delete(path)
    end
  end

  it "scrolls the dashboard through a run taller than the frame, HUD fixed" do
    routes = {
      "/alpha"   => FixtureServer::Route.new(200, "a"),
      "/bravo"   => FixtureServer::Route.new(200, "b"),
      "/charlie" => FixtureServer::Route.new(200, "c"),
      "/delta"   => FixtureServer::Route.new(200, "d"),
      "/echo"    => FixtureServer::Route.new(200, "e"),
      "/foxtrot" => FixtureServer::Route.new(200, "f"),
    }
    server = FixtureServer.new(routes)
    path = wordlist_file("alpha", "bravo", "charlie", "delta", "echo", "foxtrot")
    begin
      app = held
      app.update(JekyllHyde::Tui::KeyMsg.new("enter")) # open the cockpit
      type_field(app, 0, server.base)
      type_field(app, 1, path)
      focus(app, 3) # THREADS: clear the "40" default, set 1 so hits arrive in order
      app.update(JekyllHyde::Tui::KeyMsg.new("i"))
      3.times { app.update(JekyllHyde::Tui::KeyMsg.new("backspace")) }
      app.update(JekyllHyde::Tui::KeyMsg.new("1"))
      app.update(JekyllHyde::Tui::KeyMsg.new("esc"))
      app.update(JekyllHyde::Tui::ResizeMsg.new(100, 16)) # capacity 4, so 6 hits overflow
      _, command = app.update(JekyllHyde::Tui::KeyMsg.new("enter"))
      pump(app, command)
      # newest-first, four fit: foxtrot down to charlie; alpha/bravo are off-screen
      shows_at?(app, "/foxtrot", 16).should be_true
      shows_at?(app, "/alpha", 16).should be_false
      shows_at?(app, "of 6", 16).should be_true      # the position readout proves more exist
      app.update(JekyllHyde::Tui::KeyMsg.new("end")) # scroll to the oldest
      shows_at?(app, "/alpha", 16).should be_true
      shows_at?(app, "/foxtrot", 16).should be_false
      app.update(JekyllHyde::Tui::KeyMsg.new("home")) # back to the newest
      shows_at?(app, "/foxtrot", 16).should be_true
      shows_at?(app, "/alpha", 16).should be_false
    ensure
      server.stop
      File.delete(path)
    end
  end
end
