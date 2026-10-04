# frozen_string_literal: true

require "strscan"

# Just enough of a VT100 to check what a Screen leaves on the terminal: text
# with autowrap, CR/LF with scrolling into a scrollback, cursor up/forward,
# erase below (ESC[J), erase to the end of the row (ESC[K), clear screen and home. Colours and private modes are
# ignored. Each character takes one column.
class VirtualTerminal
  attr_reader :rows, :columns, :scrollback, :cursor

  def initialize(rows: 10, columns: 20)
    @rows = rows
    @columns = columns
    @screen = Array.new(rows) { +"" }
    @scrollback = []
    @cursor = [0, 0] # [row, column]
    @pending_wrap = false
  end

  # The IO a Screen writes to.
  def write(bytes)
    feed(bytes)
    bytes.bytesize
  end

  def flush = self

  # @return [Array<String>] the screen's rows, trailing blank rows dropped
  def lines
    rows = @screen.map(&:rstrip)
    rows.pop while rows.last == ""
    rows
  end

  private

  def feed(bytes)
    scanner = StringScanner.new(bytes)
    until scanner.eos?
      if scanner.scan(/\e\[\?[0-9;]*[hl]/) then nil
      elsif (m = scanner.scan(/\e\[([0-9;]*)([A-Za-z])/)) then csi(scanner[1], scanner[2], m)
      elsif scanner.scan("\r") then carriage_return
      elsif scanner.scan("\n") then line_feed
      else put(scanner.getch)
      end
    end
  end

  def csi(params, final, raw)
    n = params.empty? ? 1 : params.to_i
    case final
    when "m" then nil
    when "A" then @cursor[0] = [@cursor[0] - n, 0].max
    when "C" then @cursor[1] = [@cursor[1] + n, @columns - 1].min
    when "J"
      if params == "2"
        @screen.map!(&:clear)
      else
        @screen[@cursor[0]] = @screen[@cursor[0]][0, @cursor[1]]
        ((@cursor[0] + 1)...@rows).each { |row| @screen[row] = +"" }
      end
    when "K" then @screen[@cursor[0]] = @screen[@cursor[0]][0, @cursor[1]]
    when "H" then @cursor = [0, 0]
    else raise ArgumentError, "unsupported escape #{raw.inspect}"
    end
    @pending_wrap = false
  end

  def carriage_return
    @cursor[1] = 0
    @pending_wrap = false
  end

  def line_feed
    @pending_wrap = false
    if @cursor[0] == @rows - 1
      @scrollback << @screen.shift.rstrip
      @screen << +""
    else
      @cursor[0] += 1
    end
  end

  def put(char)
    if @pending_wrap
      carriage_return
      line_feed
    end
    row = @screen[@cursor[0]]
    row << (" " * (@cursor[1] - row.length)) if row.length < @cursor[1]
    row[@cursor[1]] = char
    if @cursor[1] == @columns - 1
      @pending_wrap = true
    else
      @cursor[1] += 1
    end
  end
end
