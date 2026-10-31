require "uuid"
require "uri"
require "../http/client"
require "../http/pool"
require "../core/response"
require "./wildcard_filter"
require "./similarity_filter"

module JekyllHyde::Hyde
  # Wildcard / not-found calibration for Hyde: probe six random nonexistent paths
  # under the directory being scanned, group the answers by status, and for each
  # group of two or more that agrees, learn a WildcardFilter over the dimensions
  # (size, words, lines) that stayed constant. As a fallback it also builds a
  # SimHash SimilarityFilter from each group's first body, so near-duplicates of
  # the soft-404 are dropped even when their exact counts differ.
  class Calibration
    # The six probes: {path prefix, unique-token length in 32-char blocks}.
    PROBES = [{"", 1}, {"", 3}, {".htaccess", 1}, {".htaccess", 3}, {"admin", 1}, {"admin", 3}]

    # What a round of probing learned: exact-dimension wildcard filters and the
    # SimHash near-duplicate fallbacks.
    record Learned, wildcards : Array(WildcardFilter), similarities : Array(SimilarityFilter)

    # One probe answer, keeping the decoded body the SimilarityFilter needs.
    private record Probe, response : Core::Response, text : String

    @path : String

    def initialize(@base : String, @options : Http::Options = Http::Options.hyde)
      path = URI.parse(@base).path
      path = "/" if path.empty?
      path += "/" unless path.ends_with?("/")
      @path = path
    end

    # Probe and learn the filters. Needs two or more answers to decide anything.
    def learn : Learned
      probes = probe
      return Learned.new([] of WildcardFilter, [] of SimilarityFilter) if probes.size < 2
      examine(probes)
    end

    # Probe the six paths concurrently, so an unreachable host fails in one
    # timeout, not six.
    private def probe : Array(Probe)
      paths = PROBES.map { |prefix, length| "#{@path}#{prefix}#{unique_string(length)}" }
      probes = [] of Probe
      Http::Pool.new(@base, @options, paths.size).run(paths) do |job|
        if outcome = job.outcome
          text = String.new(outcome.body).scrub
          response = Core::Response.hyde(job.path, outcome.status, outcome.body, outcome.location, text: text)
          probes << Probe.new(response, text)
        end
      end
      probes
    end

    # Group by status; within each group of two or more, keep the dimensions
    # constant across it and learn a SimHash filter from the first body. The
    # count sentries reset per status group (matters only on a multi-status set).
    private def examine(probes : Array(Probe)) : Learned
      wildcards = [] of WildcardFilter
      similarities = [] of SimilarityFilter
      probes.group_by(&.response.status).each_value do |group|
        next if group.size < 2
        first = group.first.response
        size = group.all?(&.response.size.==(first.size)) ? first.size : nil
        words = group.all?(&.response.words.==(first.words)) ? first.words : nil
        lines = group.all?(&.response.lines.==(first.lines)) ? first.lines : nil
        next unless size || words || lines
        wildcards << WildcardFilter.new(first.status, size, words, lines)
        similarities << SimilarityFilter.from(group.first.text)
      end
      Learned.new(wildcards, similarities)
    end

    private def unique_string(length : Int32) : String
      String.build { |io| length.times { io << UUID.random.hexstring } }
    end
  end
end
