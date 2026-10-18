require "../core/response"

module JekyllHyde::Hyde
  # A learned not-found fingerprint: a status and
  # the body dimensions that stayed constant across the random-path probes. A
  # response is a wildcard, and dropped, when its status matches and every set
  # dimension matches. Calibration always sets at least one dimension. A record,
  # so accumulated filters compare by value and deduplicate.
  record WildcardFilter, status : Int32, size : Int64? = nil, words : Int32? = nil, lines : Int32? = nil do
    # True when *response* looks like this learned 404/wildcard.
    def matches?(response : Core::Response) : Bool
      return false unless size || words || lines
      return false unless response.status == status
      return false if (value = size) && response.size != value
      return false if (value = words) && response.words != value
      return false if (value = lines) && response.lines != value
      true
    end
  end
end
