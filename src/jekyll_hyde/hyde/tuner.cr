module JekyllHyde::Hyde
  # Auto-tune, opt-in and off by default. It samples failures over a sliding
  # window of one round of requests and adjusts at the end of each window: it
  # backs off when failures spike (general request errors reach max(C/2, 25),
  # 403s reach 90% of the window, or 429s reach 30%) and otherwise doubles back
  # up toward the original. It is throughput only; findings are unchanged. The
  # window counters reset each round, so the backoff never latches and the
  # double-up recovery stays reachable once a flood subsides: a rate is only
  # meaningful over a recent window, where lifetime totals would hold the scan
  # down for errors it already recovered from. A 503 is not a trigger (it is a
  # response, not a request error).
  class Tuner
    HIGH_ERROR_RATIO = 0.90

    getter concurrency : Int32

    def initialize(@original : Int32, *, @enabled : Bool = false)
      @concurrency = @original
      @window = 0
      @errors = 0
      @status403 = 0
      @status429 = 0
    end

    # Record one request's result (its status, or error: true for a failed
    # request) and adjust concurrency once a full window has elapsed.
    def observe(status : Int32, error : Bool = false) : Nil
      @window += 1
      @errors += 1 if error
      @status403 += 1 if status == 403
      @status429 += 1 if status == 429
      adjust
    end

    private def adjust : Nil
      return unless @enabled
      return if @window < Math.max(@original, 50)
      if triggered?
        @concurrency = Math.max(@concurrency // 2, 1)
      elsif @concurrency < @original
        @concurrency = Math.min(@concurrency * 2, @original)
      end
      reset_window
    end

    private def reset_window : Nil
      @window = 0
      @errors = 0
      @status403 = 0
      @status429 = 0
    end

    private def triggered? : Bool
      @errors >= Math.max(@original // 2, 25) ||
        ratio(@status403) >= HIGH_ERROR_RATIO ||
        ratio(@status429) >= HIGH_ERROR_RATIO / 3.0
    end

    private def ratio(count : Int32) : Float64
      @window.zero? ? 0.0 : count.to_f / @window
    end
  end
end
