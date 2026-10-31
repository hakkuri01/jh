module JekyllHyde::Http
  # The raw result of one probe, before counting and filtering: the final status,
  # the body as raw bytes (capped, kept raw so each mode counts its own way),
  # whether the cap truncated it, a redirect Location, how long the request took
  # (time to first byte, for Jekyll's time matcher/filter), and the headers
  # serialized for Jekyll's regex rule ("Name: value\r\n" per value).
  # Core::Metrics and the mode filters turn this into a Core::Response downstream.
  record Outcome,
    status : Int32,
    body : Bytes,
    truncated : Bool,
    location : String?,
    duration : Time::Span = Time::Span.zero,
    headers : String = ""
end
