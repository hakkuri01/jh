require "http/server"

# A loopback HTTP server for engine specs: a fixed route map, a default 404, and
# an optional wildcard mode where every unknown path answers 200 (for the
# wildcard-calibration tests to come). It binds 127.0.0.1 on an ephemeral port,
# runs in a fiber, and is spec-only, never shipped (builder-security: a loopback
# dev fixture is private, so it carries no auth gate). It also tracks the peak
# number of concurrent requests, so a spec can pin a pool's in-flight cap.
class FixtureServer
  record Route,
    status : Int32,
    body : String,
    content_type : String = "text/html",
    location : String? = nil,
    delay : Time::Span = Time::Span.zero

  getter port : Int32
  getter max_in_flight : Int32 = 0
  # Every request path the server received, so a spec can assert what actually
  # went on the wire (not just what the engine reported), plus the method and
  # headers of each, appended in lockstep.
  getter received = [] of String
  getter received_methods = [] of String
  getter received_headers = [] of HTTP::Headers

  def initialize(@routes : Hash(String, Route) = {} of String => Route, *, @wildcard : Bool = false, @delay : Time::Span = Time::Span.zero, @responder : Proc(String, Route?)? = nil)
    @in_flight = 0
    @server = HTTP::Server.new { |context| handle(context) }
    address = @server.bind_tcp("127.0.0.1", 0)
    @port = address.port
    spawn @server.listen
    Fiber.yield
  end

  # The origin to point a client at.
  def base : String
    "http://127.0.0.1:#{@port}"
  end

  def stop : Nil
    @server.close
  end

  private def handle(context : HTTP::Server::Context) : Nil
    @in_flight += 1
    @max_in_flight = Math.max(@max_in_flight, @in_flight)
    begin
      respond(context)
    ensure
      @in_flight -= 1
    end
  end

  private def respond(context : HTTP::Server::Context) : Nil
    path = context.request.path
    @received << path
    @received_methods << context.request.method
    @received_headers << context.request.headers
    sleep(@delay) unless @delay.zero?
    route = @routes[path]?
    route ||= @responder.try(&.call(path))
    route ||= Route.new(200, "wildcard") if @wildcard
    unless route
      context.response.status_code = 404
      context.response.print("not found")
      return
    end
    sleep(route.delay) unless route.delay == Time::Span.zero
    context.response.status_code = route.status
    context.response.content_type = route.content_type
    route.location.try { |location| context.response.headers["Location"] = location }
    context.response.print(route.body)
  end
end
