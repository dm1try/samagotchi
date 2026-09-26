# frozen_string_literal: true

require "json"

module Samagotchi
  module Tools
    # A registry (plugin) tool's structured arguments. The parsers put what
    # the model gave on call[:args] (string keys) for any tool that is not a
    # built-in; .coerce then types the values by the tool's schema, since
    # Qwen's <parameter=…> values are all text and Gemma's bare ones may be.
    module Args
      module_function

      # Gemma 4's native call body (+text:<|"|>hi<|"|>,n:3,tags:[…],opt:{…}+,
      # without the outer braces) as a Hash; nil when it doesn't parse.
      # @param raw [String]
      # @param delim [String] the profile's string delimiter (<|"|>)
      def parse_gemma(raw, delim)
        GemmaReader.new(raw.to_s, delim).object_body
      rescue GemmaReader::Invalid
        nil
      end

      # +args+ with each value typed by its property in +parameters+ (a JSON
      # Schema object): integer, number and boolean from their text, array
      # and object from JSON text, and a scalar given for a string as text.
      # A value that doesn't fit its type stays as it came; keys the schema
      # doesn't name pass through.
      # @param args [Hash] string keys
      # @param parameters [Hash, nil] {type: "object", properties: {…}}
      # @return [Hash] string keys
      def coerce(args, parameters)
        properties = field(parameters, :properties)
        return args.to_h { |key, value| [key.to_s, value] } unless properties.is_a?(Hash)

        args.to_h do |key, value|
          spec = field(properties, key)
          [key.to_s, spec.is_a?(Hash) ? coerce_value(value, spec) : value]
        end
      end

      def coerce_value(value, spec)
        case type_of(spec)
        when "integer" then to_integer(value)
        when "number" then to_number(value)
        when "boolean" then to_boolean(value)
        when "string" then value.is_a?(Numeric) || value == true || value == false ? value.to_s : value
        when "array"
          list = from_json(value, Array)
          items = field(spec, :items)
          list.is_a?(Array) && items.is_a?(Hash) ? list.map { |item| coerce_value(item, items) } : list
        when "object"
          hash = from_json(value, Hash)
          hash.is_a?(Hash) ? coerce(hash, spec) : hash
        else value
        end
      end

      # The first non-null type ("type": ["string", "null"] is common in MCP).
      def type_of(spec)
        Array(field(spec, :type)).map(&:to_s).find { |type| type != "null" }
      end

      def to_integer(value)
        case value
        when String then value.strip.match?(/\A-?\d+\z/) ? Integer(value.strip, 10) : value
        when Float then value == value.floor ? value.to_i : value
        else value
        end
      end

      def to_number(value)
        return value unless value.is_a?(String)

        text = value.strip
        return Integer(text, 10) if text.match?(/\A-?\d+\z/)

        Float(text)
      rescue ArgumentError
        value
      end

      def to_boolean(value)
        return value unless value.is_a?(String)

        case value.strip.downcase
        when "true" then true
        when "false" then false
        else value
        end
      end

      def from_json(value, klass)
        return value unless value.is_a?(String)

        parsed = JSON.parse(value)
        parsed.is_a?(klass) ? parsed : value
      rescue JSON::ParserError
        value
      end

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]
      end

      # A small reader for Gemma's value syntax: <|"|>text<|"|>, "text" or
      # 'text', numbers, true/false/null, [a, b] and {key: value}; a bare
      # word runs to the next , ] or }.
      class GemmaReader
        class Invalid < StandardError; end

        def initialize(text, delim)
          @text = text
          @delim = delim
          @pos = 0
        end

        # The whole text as an object's pairs.
        def object_body
          skip_space
          return {} if @pos == @text.length

          hash = pairs(nil)
          skip_space
          raise Invalid unless @pos == @text.length

          hash
        end

        private

        def pairs(close)
          hash = {}
          skip_space
          return hash if close && peek == close

          loop do
            key = read_key
            skip_space
            raise Invalid unless peek == ":"

            @pos += 1
            hash[key] = read_value
            skip_space
            break unless peek == ","

            @pos += 1
            skip_space
            break if close && peek == close # a trailing comma
          end
          hash
        end

        def read_key
          skip_space
          return read_string if string_start?

          start = @pos
          @pos += 1 while @pos < @text.length && @text[@pos].match?(/\w/)
          raise Invalid if @pos == start

          @text[start...@pos]
        end

        def read_value
          skip_space
          return read_string if string_start?

          case peek
          when "[" then read_list
          when "{"
            @pos += 1
            hash = pairs("}")
            expect("}")
            hash
          else read_bare
          end
        end

        def read_list
          @pos += 1
          list = []
          skip_space
          until peek == "]"
            list << read_value
            skip_space
            break unless peek == ","

            @pos += 1
            skip_space
          end
          expect("]")
          list
        end

        def string_start? = @text[@pos, @delim.length] == @delim || peek == '"' || peek == "'"

        def read_string
          if @text[@pos, @delim.length] == @delim
            start = @pos + @delim.length
            close = @text.index(@delim, start) or raise Invalid
            @pos = close + @delim.length
            return @text[start...close]
          end

          quote = peek
          @pos += 1
          out = +""
          while @pos < @text.length
            char = @text[@pos]
            if char == "\\" && @pos + 1 < @text.length
              nxt = @text[@pos + 1]
              out << { "n" => "\n", "t" => "\t" }.fetch(nxt, nxt)
              @pos += 2
            elsif char == quote
              @pos += 1
              return out
            else
              out << char
              @pos += 1
            end
          end
          raise Invalid
        end

        def read_bare
          start = @pos
          @pos += 1 while @pos < @text.length && !",]}".include?(@text[@pos])
          word = @text[start...@pos].strip
          raise Invalid if word.empty?

          case word
          when "true" then true
          when "false" then false
          when "null" then nil
          when /\A-?\d+\z/ then Integer(word, 10)
          when /\A-?\d+\.\d+(?:[eE][-+]?\d+)?\z/ then Float(word)
          else word
          end
        end

        def expect(char)
          skip_space
          raise Invalid unless peek == char

          @pos += 1
        end

        def peek = @text[@pos]

        def skip_space
          @pos += 1 while @pos < @text.length && @text[@pos].match?(/\s/)
        end
      end
    end
  end
end
