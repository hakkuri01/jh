module JekyllHyde::Hyde
  # Auto-tune, opt-in and off by default. Once a full round of requests has gone
  # out, it backs off when failures spike: general request errors reach
  # max(C/2, 25), 403s reach 90% of requests, or 429s reach 30%. It is throughput
  # only; findings are unchanged. The back-off lowers the scan's concurrency in a
  # halve-down / double-up step with a one-round cooldown; a 503 is not a trigger
  # (it is a response, not a request error).
  class Tuner
    HIGH_ERROR_RATIO = 0.90

    getter concurrency : Int32

    def initialize(@original : Int32, *, @enabled : Bool = false)
      @concurrency = @original
      @requests = 0
      @errors = 0
      @status403 = 0
      @status429 = 0
      @last_adjust = 0
    end

    # Record one request's result (its status, or error: true for a failed
    # request) and adjust concurrency once a tuning round has elapsed.
    def observe(status : Int32, error : Bool = false) : Nil
      @requests += 1
      @errors += 1 if error
      @status403 += 1 if status == 403
      @status429 += 1 if status == 429
      adjust
    end

    private def adjust : Nil
      return unless @enabled
      round = Math.max(@original, 50)
      return if @requests < round || @requests - @last_adjust < round
      @last_adjust = @requests
      if triggered?
        @concurrency = Math.max(@concurrency // 2, 1)
      elsif @concurrency < @original
        @concurrency = Math.min(@concurrency * 2, @original)
      end
    end

    private def triggered? : Bool
      @errors >= Math.max(@original // 2, 25) ||
        ratio(@status403) >= HIGH_ERROR_RATIO ||
        ratio(@status429) >= HIGH_ERROR_RATIO / 3.0
    end

    private def ratio(count : Int32) : Float64
      @requests.zero? ? 0.0 : count.to_f / @requests
    end
  end
end
