require "./jekyll/rule"
require "./jekyll/rules"
require "./jekyll/input"

module JekyllHyde
  # A fully described scan: the one currency between the command-line front door
  # and the running engine. The command line fills every field; the cockpit form
  # fills the subset it exposes (url, one wordlist, extensions, threads, depth,
  # and in Jekyll a status matcher and filter) and leaves the rest at their
  # defaults. The parse-tracking predicates (mode_set, jekyll_used, hyde_used)
  # are set only by the CLI parser, which uses them to reject a missing or
  # wrong-mode flag; they stay false for a form-composed scan, which cannot
  # express a wrong-mode flag in the first place.
  class ScanConfig
    property mode = "HYDE"
    property url = ""
    # "-w" specs, each "path" or "path:KEYWORD" (Hyde ignores the keyword).
    property wordlists = [] of String
    property extensions = [] of String
    property threads = 40
    property depth = 4
    property? no_recursion = false
    property? auto_tune = false
    property matchers = [] of Jekyll::Rule
    property filters = [] of Jekyll::Rule
    property matcher_mode = Jekyll::Rules::Mode::Or
    property filter_mode = Jekyll::Rules::Mode::Or
    property? calibrate = false
    property input_mode = Jekyll::Input::Mode::Clusterbomb
    property output : String? = nil
    property format = "json"
    property? mode_set = false
    property? jekyll_used = false
    property? hyde_used = false

    # Add a status matcher from a cockpit field. A blank or malformed value is
    # dropped rather than raised, so a stray keystroke in the form never aborts a
    # scan; the command line, by contrast, reports a bad value and refuses to
    # launch.
    def match_status(value : String) : Nil
      add_status(@matchers, value)
    end

    def filter_status(value : String) : Nil
      add_status(@filters, value)
    end

    private def add_status(into : Array(Jekyll::Rule), value : String) : Nil
      return if value.strip.empty?
      into << Jekyll::Rule.build("status", value)
    rescue ArgumentError
      # a malformed status list from a form field is dropped, not fatal
    end
  end
end
