require "../../spec_helper"
require "../../../src/jekyll_hyde/view/results"

private def canvas : JekyllHyde::View::Scene::Canvas
  JekyllHyde::View::Scene::Canvas.new(100, 40, false)
end

private def hit(url : String, status : Int32) : JekyllHyde::Core::Response
  JekyllHyde::Core::Response.new(url, status, 10_i64, 2, 1)
end

private def progress(running : Bool, error : String? = nil, elapsed : Float64 = 0.0, requests : Int32 = 0, errors : Int32 = 0) : JekyllHyde::View::Results::Progress
  JekyllHyde::View::Results::Progress.new(running, error, elapsed, requests, errors)
end

private def state(hits : Array(JekyllHyde::Core::Response), prog : JekyllHyde::View::Results::Progress, target : String = "http://host") : JekyllHyde::View::Results::State
  JekyllHyde::View::Results::State.new("HYDE", target, hits, prog)
end

# The frame's rows as plain text, so content can be matched by substring.
private def lines(grid : JekyllHyde::Render::Grid) : Array(String)
  grid.cells.map { |line| String.build { |io| line.each { |cell| io << cell[0] } } }
end

private def shows?(grid : JekyllHyde::Render::Grid, text : String) : Bool
  lines(grid).any?(&.includes?(text))
end

describe JekyllHyde::View::Results do
  it "lists kept hits as rows with their status and path, origin stripped" do
    hits = [hit("http://host/admin", 200), hit("http://host/secret", 301)]
    grid = JekyllHyde::View::Results.frame(canvas, state(hits, progress(true, requests: 3)))
    shows?(grid, "/admin").should be_true
    shows?(grid, "/secret").should be_true
    shows?(grid, "2 results").should be_true
    shows?(grid, "http://host").should be_true
    shows?(grid, "RESULTS").should be_true
    shows?(grid, "SCANNING").should be_true
  end

  it "sanitizes a hostile extracted path before it reaches a cell" do
    grid = JekyllHyde::View::Results.frame(canvas, state([hit("http://host/a\e[2Jx", 200)], progress(false)))
    lines(grid).each(&.should_not(contain('\e')))
    shows?(grid, "COMPLETE").should be_true
  end

  it "shows a failure as one line, not the hit table" do
    empty = [] of JekyllHyde::Core::Response
    grid = JekyllHyde::View::Results.frame(canvas, state(empty, progress(false, error: "no such wordlist")))
    shows?(grid, "error: no such wordlist").should be_true
    shows?(grid, "HALTED").should be_true
    shows?(grid, "PATH").should be_false
  end

  it "warns when every request has errored" do
    empty = [] of JekyllHyde::Core::Response
    grid = JekyllHyde::View::Results.frame(canvas, state(empty, progress(true, requests: 40, errors: 40)))
    shows?(grid, "target not responding").should be_true
  end

  it "hints when nothing has landed after a while" do
    empty = [] of JekyllHyde::Core::Response
    grid = JekyllHyde::View::Results.frame(canvas, state(empty, progress(true, elapsed: 25.0, requests: 5)))
    shows?(grid, "no results yet").should be_true
  end

  it "shows a paused scan as a steady PAUSED rail, not the pulse" do
    grid = JekyllHyde::View::Results.frame(canvas, state([hit("http://host/x", 200)], progress(true, requests: 3).copy_with(paused: true)))
    shows?(grid, "PAUSED").should be_true
    shows?(grid, "SCANNING").should be_false
  end

  it "windows a tall run by the scroll offset and shows a position readout" do
    hits = (1..10).map { |n| hit("http://host/p%02d" % n, 200) }
    small = JekyllHyde::View::Scene::Canvas.new(100, 16, false) # capacity 4
    top = JekyllHyde::View::Results.frame(small, state(hits, progress(false)))
    shows?(top, "/p10").should be_true  # newest at the head
    shows?(top, "/p01").should be_false # oldest off the bottom
    shows?(top, "of 10").should be_true
    scrolled = JekyllHyde::View::Results.frame(small, JekyllHyde::View::Results::State.new("HYDE", "http://host", hits, progress(false), 6))
    shows?(scrolled, "/p01").should be_true  # oldest now in view
    shows?(scrolled, "/p10").should be_false # newest scrolled off the top
  end
end
