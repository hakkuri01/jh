require "./spec_helper"

# Seam spec (mirrors no single file): the scan engine is renderer-agnostic, so
# nothing under the engine namespaces may name the view or runtime layer. A
# non-comment hit fails the suite: a layering ratchet.
describe "architecture boundary" do
  it "keeps the engine free of View/Tui/Render references" do
    engine_dirs = %w[core http wordlist filter results hyde jekyll mode]
    forbidden = /\b(?:View|Tui|Render)::/
    root = File.expand_path("../src/jekyll_hyde", __DIR__)
    offenders = [] of String
    engine_dirs.each do |dir|
      base = File.join(root, dir)
      next unless Dir.exists?(base)
      Dir.glob(File.join(base, "**", "*.cr")).each do |file|
        File.each_line(file) do |line|
          next if line.lstrip.starts_with?("#")
          offenders << "#{file}: #{line.strip}" if forbidden.matches?(line)
        end
      end
    end
    offenders.should be_empty
  end
end
