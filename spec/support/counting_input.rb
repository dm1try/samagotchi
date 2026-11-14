# frozen_string_literal: true

# A rack.input that makes its body as it is read and counts the bytes read,
# so a spec can declare a 300 MB body without holding one and check what
# chi web read of it: `CountingInput.new(300 * 1024 * 1024)`, then
# `input.bytes_read`. A +prefix+ is served first (a multipart part's
# headers, a form's "token=x&"), then +fill+ repeated up to +size+ bytes.
class CountingInput
  attr_reader :bytes_read, :size

  def initialize(size, prefix: "", fill: "a")
    @size = size
    @prefix = prefix.b
    @fill = fill.b
    @pos = 0
    @bytes_read = 0
  end

  def read(length = nil, buffer = nil)
    left = @size - @pos
    if left <= 0
      buffer&.clear
      return length.nil? || length.zero? ? "" : nil
    end

    count = length.nil? ? left : [length, left].min
    chunk = bytes_at(@pos, count)
    @pos += count
    @bytes_read += count
    buffer ? buffer.replace(chunk) : chunk
  end

  def gets
    read(1024)
  end

  def each
    while (chunk = read(16 * 1024))
      yield chunk
    end
  end

  def rewind
    @pos = 0
  end

  def close = nil

  private

  def bytes_at(pos, count)
    out = +"".b
    if pos < @prefix.bytesize
      out << @prefix.byteslice(pos, count)
      pos += out.bytesize
    end
    rest = count - out.bytesize
    return out if rest <= 0

    offset = (pos - @prefix.bytesize) % @fill.bytesize
    out << (@fill * ((rest / @fill.bytesize) + 2)).byteslice(offset, rest)
  end
end
