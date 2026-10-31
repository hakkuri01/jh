require "json"
require "csv"
require "./response"
require "./sanitize"

# The append-only record of a scan's kept results, with JSON and CSV export.
# Secret-safe by construction: a result is a Core::Response, which holds no
# request headers or cookies, so no auth material can reach an export file.
# Remote-derived fields (the URL and any redirect Location) are sanitized before
# serialization, since an export is a filesystem boundary just like the terminal
# (AGENTS Security 1).
module JekyllHyde::Core
  class Results
    getter entries : Array(Response)

    def initialize(@entries : Array(Response) = [] of Response)
    end

    # Append a kept result. Safe under the single-thread fiber scheduler, where
    # the append never yields; a multi-thread pool would guard this with a mutex.
    def <<(result : Response) : Nil
      @entries << result
    end

    def size : Int32
      @entries.size
    end

    def empty? : Bool
      @entries.empty?
    end

    # The results as a JSON array, one object per kept result.
    def to_json : String
      JSON.build do |json|
        json.array do
          @entries.each do |result|
            json.object do
              json.field "url", Core.sanitize(result.url)
              json.field "status", result.status
              json.field "size", result.size
              json.field "words", result.words
              json.field "lines", result.lines
              json.field "location", result.location.try { |loc| Core.sanitize(loc) }
            end
          end
        end
      end
    end

    # The results as RFC 4180 CSV with a header row. The stdlib quotes any field
    # holding a comma, quote, or newline, so a hostile URL cannot break the row.
    def to_csv : String
      CSV.build do |csv|
        csv.row "url", "status", "size", "words", "lines", "location"
        @entries.each do |result|
          csv.row csv_cell(result.url), result.status, result.size, result.words, result.lines, csv_cell(result.location || "")
        end
      end
    end

    # The results serialized in *format* ("csv" or anything else = JSON).
    def serialize(format : String) : String
      format == "csv" ? to_csv : to_json
    end

    # Write the results atomically and safely: the data goes to a randomly named,
    # 0600, exclusively created temp file in the target's directory, then renamed
    # over it. The random name (not a predictable PID one) stops a local attacker
    # pre-planting a symlink at the temp path. Raises File::Error on failure.
    def write(path : String, format : String) : Nil
      tmp = File.tempfile("jh", ".part", dir: File.dirname(path))
      begin
        tmp.print(serialize(format))
        tmp.close
        File.rename(tmp.path, path)
      rescue ex
        tmp.close rescue nil
        File.delete?(tmp.path)
        raise ex
      end
    end

    # A CSV cell for untrusted text: sanitized of control and escape sequences,
    # with a leading spreadsheet-formula trigger (=, +, -, @) neutralized by a
    # single quote so opening the export cannot execute a hostile redirect
    # Location as a formula (CSV injection).
    private def csv_cell(value : String) : String
      cleaned = Core.sanitize(value)
      return cleaned if cleaned.empty?
      "=+-@".includes?(cleaned[0]) ? "'#{cleaned}" : cleaned
    end
  end
end
