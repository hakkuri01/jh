# The wordlist a scan draws from: one or more files loaded into an ordered list
# with the effective count and a case-insensitive find. Two load disciplines,
# one per mode; loaded O(W) once, iterated per scan.
module JekyllHyde::Wordlist
  class List
    getter entries : Array(String)

    def initialize(@entries : Array(String))
    end

    # Hyde discipline: merge *paths* into one deduplicated,
    # first-seen-ordered list, dropping blanks and `#` comments and trimming a
    # leading `/`. Dedup is safe with no positional coupling. Raises if unreadable.
    def self.deduplicated(paths : Enumerable(String)) : List
      entries = [] of String
      seen = Set(String).new
      paths.each do |path|
        File.each_line(path) do |line|
          word = clean(line)
          entries << word if word && seen.add?(word)
        end
      end
      new(entries)
    end

    # Jekyll discipline: keep every line in file order, trimming only a
    # CRLF `\r`. No dedup or filtering; clusterbomb and pitchfork address
    # wordlists by index and resume by position, so a dropped line changes results.
    def self.positional(paths : Enumerable(String)) : List
      entries = [] of String
      paths.each do |path|
        File.each_line(path) { |line| entries << line.rstrip('\r') }
      end
      new(entries)
    end

    # A cleaned entry, or nil for a comment or blank line.
    private def self.clean(line : String) : String?
      word = line.rstrip('\r')
      return nil if word.empty? || word.starts_with?('#')
      word = word.lstrip('/')
      word.empty? ? nil : word
    end

    def size : Int32
      @entries.size
    end

    def empty? : Bool
      @entries.empty?
    end

    # Entries containing *query* case-insensitively: the TUI wordlist find. One
    # O(W) pass; an empty query returns a copy of every entry.
    def find(query : String) : Array(String)
      return @entries.dup if query.empty?
      needle = query.downcase
      @entries.select(&.downcase.includes?(needle))
    end
  end
end
