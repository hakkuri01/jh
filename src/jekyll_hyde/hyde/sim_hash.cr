require "./stop_words"

module JekyllHyde::Hyde
  # A 64-bit SimHash near-duplicate signature over a preprocessed token stream.
  # Hyde builds one from each soft-404 probe body and drops any later response
  # within a small Hamming distance of it, catching near-duplicates the exact
  # size/word/line filter misses. Each token is hashed with keyed SipHash-2-4
  # (keys 1, 2) over its bytes followed by a 0xff terminator.
  module SimHash
    extend self

    # Punctuation replaced with a space before tokenizing. Note `-` and `_` are
    # kept, so they stay in words.
    PUNCT = Set{'!', '\\', '"', '#', '$', '%', '&', '(', ')', '*', '+', ':', ';',
                '<', '=', '>', '?', '@', '[', ']', '^', '{', '}', '|', '~', ',',
                '\'', '“', '”', '’', '‘', '/', '–', '\u{2014}', '.'}

    # Word boundary regex, used to find words for stop-word removal.
    WORD = /\b[a-zA-Z0-9_-]+\b/

    # SipHash's four initialization constants.
    C0 = 0x736f6d6570736575_u64
    C1 = 0x646f72616e646f6d_u64
    C2 = 0x6c7967656e657261_u64
    C3 = 0x7465646279746573_u64

    # Preprocess: punctuation to spaces, lowercase, drop stop words, split on
    # whitespace into word tokens.
    def preprocess(text : String) : Array(String)
      cleaned = String.build do |io|
        text.each_char { |char| io << (PUNCT.includes?(char) ? ' ' : char) }
      end
      cleaned = cleaned.downcase
      cleaned = cleaned.gsub(WORD) { |word| STOP_WORDS.includes?(word) ? "" : word }
      cleaned.split
    end

    # Build the signature: for each token's 64-bit hash, bit i votes +1 when
    # clear and -1 when set; the signature's bit i is set when the vote is
    # positive (more tokens had it clear). An empty token stream hashes to 0.
    def signature(text : String) : UInt64
      counts = StaticArray(Int32, 64).new(0)
      preprocess(text).each do |token|
        hash = token_hash(token)
        i = 0
        while i < 64
          if (hash & 1_u64) == 0
            counts[i] += 1
          else
            counts[i] -= 1
          end
          hash >>= 1
          i += 1
        end
      end
      result = 0_u64
      i = 0
      while i < 64
        result |= (1_u64 << i) if counts[i] > 0
        i += 1
      end
      result
    end

    # The number of differing bits between two signatures.
    def hamming(a : UInt64, b : UInt64) : Int32
      (a ^ b).popcount.to_i32
    end

    # SipHash-2-4 over *data* with the two 64-bit keys.
    def siphash24(data : Bytes, key0 : UInt64, key1 : UInt64) : UInt64
      v0, v1, v2, v3 = key0 ^ C0, key1 ^ C1, key0 ^ C2, key1 ^ C3
      len = data.size
      tail = len & 7
      offset = 0
      while offset < len - tail
        m = load_u64_le(data, offset)
        v3 ^= m
        2.times { v0, v1, v2, v3 = sip_round(v0, v1, v2, v3) }
        v0 ^= m
        offset += 8
      end
      b = (len.to_u64 & 0xff_u64) << 56
      tail.times { |j| b |= data[offset + j].to_u64 << (8 * j) }
      v3 ^= b
      2.times { v0, v1, v2, v3 = sip_round(v0, v1, v2, v3) }
      v0 ^= b
      v2 ^= 0xff_u64
      4.times { v0, v1, v2, v3 = sip_round(v0, v1, v2, v3) }
      v0 ^ v1 ^ v2 ^ v3
    end

    # One token's hash: its bytes plus a 0xff terminator, then the keyed SipHash
    # (keys 1, 2).
    private def token_hash(token : String) : UInt64
      src = token.to_slice
      msg = Bytes.new(src.size + 1)
      src.copy_to(msg)
      msg[src.size] = 0xff_u8
      siphash24(msg, 1_u64, 2_u64)
    end

    private def sip_round(v0 : UInt64, v1 : UInt64, v2 : UInt64, v3 : UInt64) : {UInt64, UInt64, UInt64, UInt64}
      v0 &+= v1
      v1 = rotl(v1, 13)
      v1 ^= v0
      v0 = rotl(v0, 32)
      v2 &+= v3
      v3 = rotl(v3, 16)
      v3 ^= v2
      v0 &+= v3
      v3 = rotl(v3, 21)
      v3 ^= v0
      v2 &+= v1
      v1 = rotl(v1, 17)
      v1 ^= v2
      v2 = rotl(v2, 32)
      {v0, v1, v2, v3}
    end

    private def rotl(value : UInt64, shift : Int32) : UInt64
      (value << shift) | (value >> (64 - shift))
    end

    private def load_u64_le(data : Bytes, offset : Int32) : UInt64
      result = 0_u64
      8.times { |j| result |= data[offset + j].to_u64 << (8 * j) }
      result
    end
  end
end
