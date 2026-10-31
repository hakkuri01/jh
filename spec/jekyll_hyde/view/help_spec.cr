require "../../spec_helper"
require "../../../src/jekyll_hyde/view/help"
require "../../../src/jekyll_hyde/entry"

# The mode flags and -h are keys in the TUI, not rows on the flag reference: Tab
# switches the mode and h toggles this page, both named in Help::KEYS.
private def exempt_flags : Set(String)
  Set{"--hyde", "--jekyll", "-h", "--help"}
end

# Every flag form the help panels name, split out of their label column ("--mc /
# --fc" is two, "native" and "FUZZ" are neither).
private def panel_flags : Set(String)
  (JekyllHyde::View::Help::FLAGS +
    JekyllHyde::View::Help::HYDE +
    JekyllHyde::View::Help::JEKYLL)
    .flat_map(&.[0].split(/[\s\/]+/))
    .select(&.starts_with?('-'))
    .to_set
end

# One entry per option the real CLI parser accepts, holding that option's flag
# forms ("-u URL, --url=URL" is one option, two forms). Harvested from the parser
# so the oracle cannot drift the way a hand-copied list does.
private def parser_options : Array(Array(String))
  parser, _, _ = JekyllHyde::Entry.new(IO::Memory.new, IO::Memory.new).parse([] of String)
  parser.to_s.each_line.compact_map do |line|
    stripped = line.lstrip
    next unless stripped.starts_with?('-')
    stripped.split(/\s{2,}/, 2)[0].split(", ").map { |token| token.split(/[ =]/, 2)[0] }
  end.to_a
end

# The README promises the interactive `h` page lists every flag. These pin the
# panels against the parser in both directions, so adding a flag to the CLI
# without documenting it, or leaving a row behind after removing one, fails here.
describe JekyllHyde::View::Help do
  it "names every flag the CLI parser accepts" do
    documented = panel_flags
    undocumented = parser_options.reject do |forms|
      forms.any? { |flag| documented.includes?(flag) || exempt_flags.includes?(flag) }
    end
    undocumented.map(&.join(", ")).should be_empty
  end

  it "names no flag the CLI parser does not accept" do
    accepted = parser_options.flatten.to_set
    panel_flags.reject { |flag| accepted.includes?(flag) }.should be_empty
  end
end
