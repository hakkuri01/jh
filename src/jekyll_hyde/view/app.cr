require "../tui/model"
require "../tui/program"
require "../tui/terminal"
require "../render/graphics"
require "../scan_config"
require "./scene"
require "./shell"
require "./help"
require "./finder"
require "./results"
require "./session"
require "./app_editing"

# The interactive program.
module JekyllHyde::View
  # The whole shell as one Elm model: it opens in Hyde and plays the boot
  # sequence, which settles to the held opener on its own; the first key ends the
  # intro and acts at once (any key composes, Tab switches modes with the
  # fade-through-static animation, q quits), so no press is ever swallowed. The
  # cockpit is a small vim-modal form (NORMAL navigates with j/k or arrows, i
  # edits a field, Enter launches, q quits; Esc only leaves INSERT, so a
  # reflexive Esc can never drop the TUI) whose fields compose the live `jh …`
  # command. Once a scan runs, q clears the results back to the cockpit to
  # compose another (q again there quits), and the dashboard scrolls through a
  # run too tall to fit. Ticks run only while something is
  # animating, so a held or composing frame costs nothing until a key or a
  # resize arrives. The scan engine lands on top of this.
  class App
    include Tui::Model

    # The time between frames: 30 a second.
    FRAME = (1.0 / 30).seconds
    # How long a mode switch takes.
    SWITCH = 0.5

    # Which part of the lifecycle the app is in.
    enum Phase
      Booting
      Steady
      Switching
      Shell
      Help
      Finder
      Scanning
    end

    getter? images : Bool

    @phase : Phase
    @mode : String
    @field : Int32
    @editing : Bool
    @values : Array(String)
    @elapsed : Float64
    @progress : Float64
    @switch_from : String
    @switch_to : String
    @switch_origin : Phase
    @session : ScanSession?
    @finder : Finder::Session?
    @cursor : Int32
    @scroll : Int32
    @rows : Int32
    @scan_at : Time::Instant
    @pending : ScanConfig?

    def initialize(@images : Bool, @pending : ScanConfig? = nil)
      @phase = Phase::Booting
      @mode = "HYDE"
      @field = 0
      @editing = false
      @values = Shell.defaults(@mode)
      @elapsed = 0.0
      @progress = 0.0
      @switch_from = @mode
      @switch_to = @mode
      @switch_origin = Phase::Steady
      @session = nil
      @finder = nil
      @cursor = 0
      @scroll = 0
      @rows = 24
      @boot_at = Time.instant
      @switch_at = @boot_at
      @scan_at = @boot_at
    end

    # Opens the terminal and runs the app, uploading the face once and freeing
    # it on exit. A no-op when the terminal is not interactive.
    def self.run(output : IO = STDOUT) : Nil
      terminal = Tui::Terminal.new(STDIN, output)
      return unless terminal.interactive?
      app = new(Render::Graphics.images?)
      Tui::Program.new(app, terminal).run(Scene.setup(app.images?), Scene.teardown(app.images?))
    end

    # Launches straight into a scan composed on the command line (the power-user
    # override): the TUI opens on the running dashboard. A no-op off an interactive
    # terminal; the session is built in `init`, so an early return orphans nothing.
    def self.launch(config : ScanConfig, output : IO = STDOUT) : Nil
      terminal = Tui::Terminal.new(STDIN, output)
      return unless terminal.interactive?
      app = new(Render::Graphics.images?, config)
      Tui::Program.new(app, terminal).run(Scene.setup(app.images?), Scene.teardown(app.images?))
    end

    # Starts the boot animation, or, for a command-line scan, builds the session
    # and opens straight on the running dashboard.
    def init : Tui::Cmd?
      if config = @pending
        @pending = nil
        @mode = config.mode
        @values = Shell.defaults(@mode)
        start_scan(config)
      else
        Tui.tick(FRAME)
      end
    end

    def update(msg : Tui::Msg) : {Tui::Model, Tui::Cmd?}
      case msg
      when Tui::TickMsg   then advance(msg.at)
      when Tui::KeyMsg    then key(msg.key)
      when Tui::ResizeMsg then resize(msg)
      when ScanHitMsg     then scan_hit(msg)
      when ScanTickMsg    then scan_tick(msg)
      when ScanDoneMsg    then scan_done(msg)
      when ScanFailedMsg  then scan_failed(msg)
      else                     {self, nil}
      end
    end

    def view(width : Int32, height : Int32) : Render::Grid
      canvas = Scene::Canvas.new(width, height, @images)
      case @phase
      when .booting?   then Scene.boot(canvas, @mode, @elapsed)
      when .switching? then switching_frame(canvas)
      when .shell?     then Shell.frame(canvas, Shell::State.new(@mode, @field, @editing, @values, @cursor))
      when .help?      then Help.frame(canvas, @mode)
      when .finder?    then Finder.frame(canvas, finder_state)
      when .scanning?  then Results.frame(canvas, results_state)
      else                  Scene.steady(canvas, @mode)
      end
    end

    # The results snapshot for the running or finished scan; an empty stand-in
    # when there is no session, though the Scanning phase is only entered with one.
    private def results_state : Results::State
      if session = @session
        elapsed = (Time.instant - @scan_at).total_seconds
        progress = Results::Progress.new(session.running?, session.error, elapsed, session.requests, session.errors, session.paused?, session.warning)
        Results::State.new(@mode, session.target, session.hits, progress, @scroll)
      else
        Results::State.new(@mode, "", [] of Core::Response, Results::Progress.new(false, nil, 0.0, 0, 0), 0)
      end
    end

    # The mode-switch frame: the opener's fade-through-static when switching from
    # the hold, else the destination cockpit or help page under a static flicker.
    # The flicker plays on every switch, a locked invariant.
    private def switching_frame(canvas : Scene::Canvas) : Render::Grid
      rng = Random.new((@progress * 100).to_i)
      case @switch_origin
      when .help?  then Scene.flicker(Help.frame(canvas, @switch_to), @progress, rng)
      when .shell? then Scene.flicker(Shell.frame(canvas, Shell::State.new(@switch_to, @field, @editing, @values, @cursor)), @progress, rng)
      else              Scene.switch(canvas, @switch_from, @switch_to, @progress)
      end
    end

    # Advances the running animation to *now*, scheduling the next frame until
    # the boot sequence or the switch settles, then holding.
    private def advance(now : Time::Instant) : {Tui::Model, Tui::Cmd?}
      case @phase
      when .booting?
        @elapsed = (now - @boot_at).total_seconds
        if @elapsed >= Scene::HOLD_END
          @phase = Phase::Steady
          return {self, nil}
        end
        {self, Tui.tick(FRAME)}
      when .switching?
        @progress = (now - @switch_at).total_seconds / SWITCH
        return {self, Tui.tick(FRAME)} if @progress < 1.0
        @mode = @switch_to
        @phase = @switch_origin
        {self, nil}
      else
        {self, nil}
      end
    end

    # Routes a key by phase: the opener's first key ends the intro and acts, the
    # hold composes or switches, the shell edits, a switch animation ignores keys.
    private def key(name : String) : {Tui::Model, Tui::Cmd?}
      case @phase
      when .booting?  then wake(name)
      when .steady?   then steady_key(name)
      when .shell?    then shell_key(name)
      when .help?     then help_key(name)
      when .finder?   then finder_key(name)
      when .scanning? then scanning_key(name)
      else                 {self, nil}
      end
    end

    # The opener takes its first key at once: end the boot animation and act on
    # the key (compose, switch, or quit), so a single press is never swallowed.
    private def wake(name : String) : {Tui::Model, Tui::Cmd?}
      @phase = Phase::Steady
      steady_key(name)
    end

    # In the hold: q quits, Tab switches modes with the animation, and any other
    # key (Esc included) opens the composition cockpit in NORMAL.
    private def steady_key(name : String) : {Tui::Model, Tui::Cmd?}
      case name
      when "q"   then {self, Tui::QUIT}
      when "tab" then begin_switch
      else            open_shell
      end
    end

    private def open_shell : {Tui::Model, Tui::Cmd?}
      @phase = Phase::Shell
      @field = 0
      @editing = false
      @cursor = 0
      {self, nil}
    end

    # In the shell, NORMAL navigates and acts, INSERT edits the focused field.
    private def shell_key(name : String) : {Tui::Model, Tui::Cmd?}
      @editing ? insert_key(name) : normal_key(name)
    end

    # NORMAL keys: j/k and arrows move between fields, i edits, Enter runs, Tab
    # swaps the mode, h opens the reference, q quits. Esc is inert here, so a
    # reflexive Esc out of editing never drops the whole TUI.
    private def normal_key(name : String) : {Tui::Model, Tui::Cmd?}
      case name
      when "j", "down" then move(1)
      when "k", "up"   then move(-1)
      when "i"         then begin_insert
      when "/"         then open_finder
      when "enter"     then execute
      when "tab"       then begin_switch
      when "h"         then open_help
      when "q"         then {self, Tui::QUIT}
      else                  {self, nil}
      end
    end

    # The h page: Tab flips the mode-only panel (with the switch animation), and
    # h or q step back to the cockpit (q here steps back, it does not quit). Esc
    # is inert, matching the cheatsheet and the rule that Esc only leaves INSERT.
    private def help_key(name : String) : {Tui::Model, Tui::Cmd?}
      case name
      when "tab"    then begin_switch
      when "h", "q" then close_help
      else               {self, nil}
      end
    end

    private def open_help : {Tui::Model, Tui::Cmd?}
      @phase = Phase::Help
      {self, nil}
    end

    private def close_help : {Tui::Model, Tui::Cmd?}
      @phase = Phase::Shell
      {self, nil}
    end

    # The wordlist finder opens on `/` only when the focused field is the wordlist
    # and holds a path. The list loads once with the mode's discipline; a bad path
    # becomes an error the overlay shows, not a raise.
    private def open_finder : {Tui::Model, Tui::Cmd?}
      field = Shell.fields(@mode)[@field]
      value = @values[@field]
      return {self, nil} if field.flag != "-w" || value.empty?
      @finder = Finder::Session.new(value, @mode)
      @phase = Phase::Finder
      {self, nil}
    end

    # In the finder, the session owns the filter and scroll; it says when a key
    # means "leave". Esc/Enter close back to the form.
    private def finder_key(name : String) : {Tui::Model, Tui::Cmd?}
      finder = @finder
      return {self, nil} unless finder
      finder.handle(name, Finder.capacity(@rows)).close? ? close_finder : {self, nil}
    end

    private def close_finder : {Tui::Model, Tui::Cmd?}
      @finder = nil
      @phase = Phase::Shell
      {self, nil}
    end

    # The finder snapshot for the current frame; an empty stand-in when there is
    # no session, though the Finder phase is only entered with one.
    private def finder_state : Finder::State
      @finder.try(&.state) || Finder::State.new(@mode, "", 0, "", [] of String, 0, nil)
    end

    # INSERT caret editing and NORMAL field navigation live in app_editing.cr (a
    # reopened App), to keep this file under the size limit.

    # Run the composed scan, but only once the mandatory fields are set (target,
    # wordlist, and a FUZZ keyword in Jekyll); otherwise Enter is a no-op. The scan
    # runs on its own fiber in the session; `listen` streams each hit into the loop.
    private def execute : {Tui::Model, Tui::Cmd?}
      return {self, nil} unless ready?
      {self, start_scan(compose)}
    end

    # Build the session for *config*, open on the dashboard, and return the
    # command that streams the first hit. Shared by the Enter launch and the
    # command-line power-user launch; the caller owns @mode and @values.
    private def start_scan(config : ScanConfig) : Tui::Cmd
      session = ScanSession.new(config)
      @session = session
      @scan_at = Time.instant
      @scroll = 0
      @phase = Phase::Scanning
      session.listen(FRAME)
    end

    # A ScanConfig from the current form, reading each value by its flag (the two
    # modes' field lists differ at both ends, so fixed indices would misread).
    # Only Jekyll carries a status matcher and filter.
    private def compose : ScanConfig
      state = shell_state
      config = ScanConfig.new
      config.mode = @mode
      config.url = Shell.value(state, "-u")
      config.wordlists = [Shell.value(state, "-w")]
      config.extensions = Shell.value(state, "-e").split(',').map(&.strip).reject(&.empty?)
      config.threads = Shell.value(state, "-t").to_i? || config.threads
      config.depth = Shell.value(state, "-d").to_i? || config.depth
      if @mode == "JEKYLL"
        config.match_status(Shell.value(state, "--mc"))
        config.filter_status(Shell.value(state, "--fc"))
      end
      config
    end

    # Whether the mandatory fields are set, delegated to the shell's own check so
    # the launch gate and the READY light cannot drift apart.
    private def ready? : Bool
      Shell.ready?(shell_state)
    end

    private def shell_state : Shell::State
      Shell::State.new(@mode, @field, @editing, @values, @cursor)
    end

    # A hit from the live session: record it and wait for the next. A hit from a
    # cancelled, superseded session is ignored and not re-listened for, so its
    # fiber chain winds down.
    private def scan_hit(msg : ScanHitMsg) : {Tui::Model, Tui::Cmd?}
      session = @session
      return {self, nil} unless session && msg.session.same?(session)
      session.record(msg.response)
      # Following the newest (offset 0) keeps following; a user who has scrolled
      # back stays pinned to the same entries as newer ones land above them.
      @scroll += 1 if @scroll > 0
      {self, session.listen(FRAME)}
    end

    # A frame tick while scanning: redraw (the pulse and messages advance on
    # elapsed time) and wait for the next, as long as the scan is still live.
    private def scan_tick(msg : ScanTickMsg) : {Tui::Model, Tui::Cmd?}
      session = @session
      return {self, nil} unless session && msg.session.same?(session) && session.running?
      {self, session.listen(FRAME)}
    end

    private def scan_done(msg : ScanDoneMsg) : {Tui::Model, Tui::Cmd?}
      @session.try { |session| session.finish if msg.session.same?(session) }
      {self, nil}
    end

    private def scan_failed(msg : ScanFailedMsg) : {Tui::Model, Tui::Cmd?}
      @session.try { |session| session.fail(msg.reason) if msg.session.same?(session) }
      {self, nil}
    end

    # Results-view keys: q stops the scan and returns to the cockpit (q there
    # quits), p holds and resumes, and the arrows/j/k, PageUp/PageDown, Home/End
    # scroll the newest-first run. Esc is inert, so it cannot drop the dashboard.
    private def scanning_key(name : String) : {Tui::Model, Tui::Cmd?}
      case name
      when "q"         then stop_scan
      when "p"         then toggle_pause
      when "down", "j" then scroll_results(1)
      when "up", "k"   then scroll_results(-1)
      when "pgdown"    then scroll_results(page_rows)
      when "pgup"      then scroll_results(-page_rows)
      when "home"      then set_scroll(0)
      when "end"       then set_scroll(max_scroll)
      else                  {self, nil}
      end
    end

    # Hold or resume the running scan; p stops new requests going out without
    # tearing the dashboard down (q is the one that ends it).
    private def toggle_pause : {Tui::Model, Tui::Cmd?}
      @session.try(&.toggle_pause)
      {self, nil}
    end

    private def stop_scan : {Tui::Model, Tui::Cmd?}
      @session.try(&.cancel)
      @session = nil
      @editing = false
      @phase = Phase::Shell
      {self, nil}
    end

    # Move the dashboard window by *delta* rows (positive toward older hits),
    # clamped so it never scrolls past the oldest hit or above the newest.
    private def scroll_results(delta : Int32) : {Tui::Model, Tui::Cmd?}
      set_scroll(@scroll + delta)
    end

    private def set_scroll(offset : Int32) : {Tui::Model, Tui::Cmd?}
      @scroll = offset.clamp(0, max_scroll)
      {self, nil}
    end

    # How far the newest-first window can scroll back: the hits that do not fit
    # the dashboard at the current terminal height, or zero when they all fit.
    private def max_scroll : Int32
      hits = @session.try(&.hits.size) || 0
      Math.max(0, hits - Results.capacity(@rows))
    end

    private def page_rows : Int32
      Math.max(1, Results.capacity(@rows))
    end

    # The terminal resized: remember the height so the dashboard can clamp how
    # far its results scroll, and keep the current offset in range.
    private def resize(msg : Tui::ResizeMsg) : {Tui::Model, Tui::Cmd?}
      @rows = msg.height
      @scroll = @scroll.clamp(0, max_scroll)
      @finder.try(&.clamp(Finder.capacity(@rows)))
      {self, nil}
    end

    private def reset_form(mode : String) : Nil
      @values = Shell.defaults(mode)
      @field = 0
      @editing = false
      @cursor = 0
    end

    # Begins a mode switch from the current phase. The two modes are separate
    # engines, so the form resets to the destination mode's fields; the switch
    # always plays the static flicker and returns to the phase it began in.
    private def begin_switch : {Tui::Model, Tui::Cmd?}
      @switch_origin = @phase
      @switch_from = @mode
      @switch_to = other_mode
      @progress = 0.0
      @switch_at = Time.instant
      reset_form(@switch_to)
      @phase = Phase::Switching
      {self, Tui.tick(FRAME)}
    end

    private def other_mode : String
      @mode == "HYDE" ? "JEKYLL" : "HYDE"
    end
  end
end
