# frozen_string_literal: true

require_relative "../pages"

module Samagotchi
  module Pages
    # What a page script's `ui` is: text, table and walk, each adding one
    # block in order. #data is the page as stored (plain Hashes: it is the
    # JSON edge). A rule broken raises Refused naming the block by its place
    # on the page ("table 2: …"), and the run fails with it.
    class Builder
      attr_reader :title

      def initialize(title)
        @title = Builder.text_of(title).strip
        raise Refused, "page needs a title" if @title.empty?

        @blocks = []
      end

      # @return [Hash] {"title" => …, "blocks" => [...]}
      def data = { "title" => @title, "blocks" => @blocks }

      # A Markdown text block.
      def text(markdown)
        where = place("text")
        text = Builder.text_of(markdown)
        if text.bytesize > MAX_TEXT_BYTES
          raise Refused, "#{where} is #{kb(text.bytesize)} (at most #{MAX_TEXT_BYTES / 1024} KB)"
        end

        add("type" => "text", "text" => text)
      end

      # A table of +rows+ (Hashes, string or symbol keys). +columns+ is a
      # Hash key => label (its order kept) or an Array of keys; +format+ key
      # => :money or :count; +key+ the columns a phone shows before a row is
      # opened (default: the first two after the first whose cells are all
      # numbers or nil); +total+ one more row, by column key.
      def table(rows, columns:, format: {}, key: nil, total: nil)
        where = place("table")
        TableBlock.new(where).build(rows, columns: columns, format: format, key: key, total: total).then { |block| add(block) }
      end

      # A scenario walk: the data a chi-ui walk holds (title, actors, steps),
      # checked by the same schema (InlineWidgets.check).
      def walk(data = nil, **fields)
        where = place("walk")
        result = InlineWidgets.check("walk", data.nil? ? fields : data)
        raise Refused, "#{where}: #{result.error}" unless result.ok?

        add("type" => "walk", "data" => result.data)
      end

      # A value as text, scrubbed to valid UTF-8.
      def self.text_of(value)
        InlineWidgets::DataTree.text(value)
      end

      private

      # "table 2": the block's type and its place on the page, 1 first. A
      # page past MAX_BLOCKS fails here, before the block is built.
      def place(type)
        count = @blocks.size + 1
        raise Refused, "the page has more than #{MAX_BLOCKS} blocks (#{type} #{count} is one too many)" if count > MAX_BLOCKS

        "#{type} #{count}"
      end

      def add(block)
        @blocks << block
        nil
      end

      def kb(bytes) = format("%.1f KB", bytes / 1024.0)
    end

    # One table block, as Builder#table describes it.
    class TableBlock
      def initialize(where)
        @where = where
      end

      def build(rows, columns:, format:, key:, total:)
        keys, labels = columns(columns)
        formats = formats(format, keys)
        rows = rows(rows)
        kept = rows.first(MAX_ROWS).map { |row| keys.map { |k| TableBlock.cell(row[k]) } }
        key_columns = key_columns(key, keys, kept)
        block = { "type" => "table",
                  "columns" => keys.each_with_index.map { |k, i| column(k, labels[i], formats[k], key_columns.include?(k)) },
                  "rows" => kept }
        block["total"] = total(total, keys) unless total.nil?
        block["dropped"] = [rows.size - MAX_ROWS, 0].max
        block
      end

      # A cell as stored: a finite number stays a number (a Rational or a
      # BigDecimal as a Float), nil and true/false stay, anything else is its
      # text (NaN and Infinity too: JSON has neither), scrubbed, cut to
      # MAX_CELL characters with an ellipsis.
      def self.cell(value)
        case value
        when nil, true, false, Integer then value
        when Float then value.finite? ? value : value.to_s
        when Numeric then value.to_f.finite? ? value.to_f : value.to_s
        else
          text = Builder.text_of(value)
          text.size > MAX_CELL ? "#{text[0, MAX_CELL - 1]}…" : text
        end
      end

      private

      def columns(columns)
        pairs = case columns
                when Hash then columns.map { |k, label| [Builder.text_of(k), Builder.text_of(label)] }
                when Array then columns.map { |k| [Builder.text_of(k), Builder.text_of(k)] }
                else raise Refused, "#{@where}: columns: must be a Hash of key => label or a list of keys"
                end
        raise Refused, "#{@where}: columns: is empty" if pairs.empty?
        raise Refused, "#{@where} has #{pairs.size} columns (at most #{MAX_COLUMNS})" if pairs.size > MAX_COLUMNS

        pairs.transpose
      end

      def formats(format, keys)
        raise Refused, "#{@where}: format: must be a Hash of column => :money or :count" unless format.is_a?(Hash)

        format.to_h do |k, value|
          k = Builder.text_of(k)
          raise Refused, "#{@where}: format names #{k.inspect}, which is no column" unless keys.include?(k)
          unless value.is_a?(Symbol) && FORMATS.include?(value)
            raise Refused, "#{@where}: column #{k.inspect} has format #{value.inspect} (use :money or :count)"
          end

          [k, value.to_s]
        end
      end

      # Rows with string keys.
      def rows(rows)
        raise Refused, "#{@where}: rows must be a list of mappings" unless rows.is_a?(Array)

        rows.each_with_index.map do |row, index|
          raise Refused, "#{@where}: row #{index + 1} isn't a mapping" unless row.is_a?(Hash)

          row.transform_keys { |key| Builder.text_of(key) }
        end
      end

      # The first column always shows on a phone and isn't one of these.
      def key_columns(key, keys, rows)
        if key.nil?
          return keys.each_index.drop(1).select { |i| rows.all? { |row| row[i].nil? || row[i].is_a?(Numeric) } }
                     .first(2).map { |i| keys[i] }
        end

        Array(key).map do |k|
          k = Builder.text_of(k)
          raise Refused, "#{@where}: key names #{k.inspect}, which is no column" unless keys.include?(k)

          k
        end - [keys.first]
      end

      def total(total, keys)
        raise Refused, "#{@where}: total: must be a Hash by column" unless total.is_a?(Hash)

        total = total.transform_keys { |key| Builder.text_of(key) }
        extra = total.keys - keys
        raise Refused, "#{@where}: total names #{extra.first.inspect}, which is no column" unless extra.empty?

        keys.map { |k| TableBlock.cell(total[k]) }
      end

      def column(key, label, format, key_column)
        column = { "key" => key, "label" => label }
        column["format"] = format if format
        column["key_column"] = true if key_column
        column
      end
    end
  end
end
