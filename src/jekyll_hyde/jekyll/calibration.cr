require "../http/client"
require "../http/pool"
require "../core/response"
require "./rule"
require "./rules"
require "./template"

module JekyllHyde::Jekyll
  # Jekyll's autocalibration (the default "basic" strategy). Probes the target
  # with random "not found" strings grouped by shape; when a group's responses
  # that the matchers would keep all share a size, word, or line count, it learns
  # the most specific of those as a filter, so the real scan drops that wildcard.
  # Opt-in, and a no-op on a server that answers random paths with a proper 404.
  class Calibration
    TOKEN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".chars

    def initialize(@template : Template, @rules : Rules, @options : Http::Options = Http::Options.jekyll, @concurrency : Int32 = 40)
    end

    # The filters learned from the basic strategy's groups, deduplicated; empty
    # when nothing is constant (or the host did not answer as a wildcard).
    def learn : Array(Rule)
      learned = [] of Rule
      groups.each do |strings|
        responses = probe(strings).select { |candidate| @rules.accepts?(candidate) }
        next if responses.empty?
        rule = common_filter(responses)
        next unless rule
        first = responses.first
        next if @rules.rejects?(first) || learned.any?(&.matches?(first))
        learned << rule
      end
      learned
    end

    # The basic strategy's probe set: "admin"+rand, ".htaccess"+rand, and a bare
    # rand, each at two token lengths, generated fresh per scan.
    private def groups : Array(Array(String))
      [
        ["admin#{token(16)}", "admin#{token(8)}"],
        [".htaccess#{token(16)}", ".htaccess#{token(8)}"],
        [token(16), token(8)],
      ]
    end

    private def probe(strings : Array(String)) : Array(Candidate)
      requests = strings.map do |string|
        values = fill(string)
        headers = Http::Request.headers_from(@options.headers.map { |line| @template.fill(line, values) })
        body = @options.body.try { |raw| @template.fill(raw, values) }
        Http::Request.new(@template.fill(@options.method, values), @template.path(values), headers, body)
      end
      out = [] of Candidate
      Http::Pool.new(@template.origin, @options, requests.size).run(requests) do |job|
        if outcome = job.outcome
          response = Core::Response.jekyll("#{@template.origin}#{job.path}", outcome.status, outcome.body, outcome.location)
          out << Candidate.new(response, outcome.body, outcome.duration, outcome.headers)
        end
      end
      out
    end

    # The most specific filter the group shares: size, else word, else line; nil
    # when nothing is constant across it.
    private def common_filter(responses : Array(Candidate)) : Rule?
      first = responses.first.response
      return Rule.build("size", first.size.to_s) if responses.all?(&.response.size.==(first.size))
      return Rule.build("word", first.words.to_s) if responses.all?(&.response.words.==(first.words))
      return Rule.build("line", first.lines.to_s) if responses.all?(&.response.lines.==(first.lines))
      nil
    end

    # Every keyword position gets the calibration string, so a multi-FUZZ path is
    # complete.
    private def fill(string : String) : Hash(String, String)
      values = {} of String => String
      @template.keywords.each { |keyword| values[keyword] = string }
      values
    end

    private def token(length : Int32) : String
      String.build { |io| length.times { io << TOKEN.sample } }
    end
  end
end
