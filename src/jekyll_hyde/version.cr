# Jekyll // Hyde: a terminal web fuzzer with two modes, Hyde and Jekyll.
module JekyllHyde
  # version read from shard.yml at compile time so the two cannot drift
  VERSION = {{ read_file("#{__DIR__}/../../shard.yml").lines.find(&.starts_with?("version:")).split(":").last.strip }}
end
