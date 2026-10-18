require "./sim_hash"

module JekyllHyde::Hyde
  # Drops a response whose SimHash signature is within *cutoff* bits of a learned
  # signature. Hyde's calibration builds one from each detected soft-404 probe
  # body, so a later response that is a near-duplicate of the 404 page is filtered
  # even when its exact size, word, and line counts differ from the
  # WildcardFilter's.
  struct SimilarityFilter
    # The default soft-404 fallback cutoff, in differing bits.
    NEAR_DUPLICATE_DISTANCE = 3

    getter hash : UInt64
    getter cutoff : Int32

    def initialize(@hash : UInt64, @cutoff : Int32 = NEAR_DUPLICATE_DISTANCE)
    end

    # Build a filter from a page's text (the soft-404 body jh calibrated on).
    def self.from(text : String, cutoff : Int32 = NEAR_DUPLICATE_DISTANCE) : SimilarityFilter
      new(SimHash.signature(text), cutoff)
    end

    # Whether *signature* is a near-duplicate of this filter's learned page.
    def matches?(signature : UInt64) : Bool
      SimHash.hamming(@hash, signature) <= @cutoff
    end

    # Equality by signature, so a scan dedupes identical learned filters.
    def ==(other : SimilarityFilter) : Bool
      @hash == other.hash
    end
  end
end
