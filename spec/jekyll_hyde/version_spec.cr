require "../spec_helper"

describe JekyllHyde do
  it "exposes a non-empty version" do
    JekyllHyde::VERSION.should_not be_empty
  end
end
