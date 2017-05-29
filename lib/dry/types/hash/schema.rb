module Dry
  module Types
    class Hash < Definition
      # The built-in Hash type has constructors that you can use to define
      # hashes with explicit schemas and coercible values using the built-in types.
      #
      # Basic {Schema} evaluates default values for keys missing in input hash
      # (see {Schema#resolve_missing_value})
      #
      # @see Dry::Types::Default#evaluate
      # @see Dry::Types::Default::Callable#evaluate
      class Schema < Hash
        # @return [Hash{Symbol => Definition}]
        attr_reader :member_types

        IGNORED_DATA_KEY = :__ignored_data

        # @param [Class] _primitive
        # @param [Hash] options
        # @option options [Hash{Symbol => Definition}] :member_types
        def initialize(_primitive, options)
          @member_types = options.fetch(:member_types)
          super
        end

        # @param [Hash] hash
        # @return [Hash{Symbol => Object}]
        def call(hash)
          coerce(hash)
        end
        alias_method :[], :call

        # @param [Hash] hash
        # @param [#call] block
        # @yieldparam [Failure] failure
        # @yieldreturn [Result]
        # @return [Result]
        def try(hash, &block)
          success = true
          output  = {}

          begin
            result, ignored_data = try_coerce(hash) do |key, member_result|
              success &&= member_result.success?
              output[key] = member_result.input

              ignored_member_data = gather_ignored_data(output[key])
              if ignored_member_data.present?
                output[IGNORED_DATA_KEY] ||= {}
                output[IGNORED_DATA_KEY][key] = ignored_member_data
              end

              member_result
            end

            if ignored_data && ! ignored_data.empty?
              output[IGNORED_DATA_KEY] ||= {}
              output[IGNORED_DATA_KEY] = ignored_data.merge(output[IGNORED_DATA_KEY])
            end

          rescue ConstraintError, UnknownKeysError, SchemaError => e
            success = false
            result = e
          end

          if success
            success(output)
          else
            failure = failure(output, result)
            block ? yield(failure) : failure
          end
        end

        private

        def gather_ignored_data(output)
          if output.class.to_s == 'Hash' && output.has_key?(IGNORED_DATA_KEY)  # TODO somehow output.is_a?(Hash) always seems to return false ...
            output.delete(IGNORED_DATA_KEY)
          elsif output.class.to_s == 'Array' # TODO somehow output.is_a?(Array) always seems to return false ...
            output.inject([]) do |ignored_array_data, element|
              ignored_data = gather_ignored_data(element)
              ignored_array_data << ignored_data if ignored_data.present?
              ignored_array_data
            end
          end
        end

        def resolve_ignored_values(hash)
          (hash.keys - member_types.keys).inject({}) do |ignored_data,k|
            ignored_data[k] = hash[k]
            ignored_data
          end
        end

        # @param [Hash] hash
        # @return [Hash{Symbol => Object}]
        def try_coerce(hash)
          resolve(hash) do |type, key, value|
            yield(key, type.try(value))
          end
        end

        # @param [Hash] hash
        # @return [Hash{Symbol => Object}]
        def coerce(hash)
          result, ignored_values = resolve(hash) do |type, key, value|
            begin
              type.call(value)
            rescue ConstraintError
              raise SchemaError.new(key, value)
            end
          end
          result
        end

        # @param [Hash] hash
        # @return [Hash{Symbol => Object}]
        def resolve(hash)
          result = {}

          ignored_values = resolve_ignored_values(hash)

          member_types.each do |key, type|
            if hash.key?(key)
              result[key] = yield(type, key, hash[key])
            else
              resolve_missing_value(result, key, type)
            end
          end
          [result,ignored_values]
        end

        # @param [Hash] result
        # @param [Symbol] key
        # @param [Definition] type
        # @return [Object]
        # @see Dry::Types::Default#evaluate
        # @see Dry::Types::Default::Callable#evaluate
        def resolve_missing_value(result, key, type)
          if type.default?
            result[key] = type.evaluate
          else
            super
          end
        end
      end

      # Permissive schema raises a {MissingKeyError} if the given key is missing
      # in provided hash.
      class Permissive < Schema
        private

        # @param [Symbol] key
        # @raise [MissingKeyError] when key is missing in given input
        def resolve_missing_value(_, key, _)
          raise MissingKeyError, key
        end
      end

      # Strict hash will raise errors when keys are missing or value types are incorrect.
      # Strict schema raises a {UnknownKeysError} if there are any unexpected
      # keys in given hash, and raises a {MissingKeyError} if any key is missing
      # in it.
      # @example
      #   hash = Types::Hash.strict(name: Types::String, age: Types::Coercible::Int)
      #   hash[email: 'jane@doe.org', name: 'Jane', age: 21]
      #     # => Dry::Types::SchemaKeyError: :email is missing in Hash input
      class Strict < Permissive
        private

        # @param [Hash] hash
        # @return [Hash{Symbol => Object}]
        # @raise [UnknownKeysError]
        #   if there any unexpected key in given hash
        def resolve(hash)
          super do |member_type, key, value|
            type = member_type.default? ? member_type.type : member_type

            yield(type, key, value)
          end
        end

        def resolve_ignored_values(hash)
          unexpected = hash.keys - member_types.keys
          raise UnknownKeysError.new(*unexpected) unless unexpected.empty?
        end
      end

      # {StrictWithDefaults} checks that there are no extra keys
      # (raises {UnknownKeysError} otherwise) and there a no missing keys
      # without default values given (raises {MissingKeyError} otherwise).
      # @see Default#evaluate
      # @see Default::Callable#evaluate
      class StrictWithDefaults < Strict
        private

        # @param [Hash] result
        # @param [Symbol] key
        # @param [Definition] type
        # @return [Object]
        # @see Dry::Types::Default#evaluate
        # @see Dry::Types::Default::Callable#evaluate
        def resolve_missing_value(result, key, type)
          if type.default?
            result[key] = type.evaluate
          else
            super
          end
        end
      end

      # Weak schema provides safe types for every type given in schema hash
      # @see Safe
      class Weak < Schema
        # @param [Class] primitive
        # @param [Hash] options
        # @see #initialize
        def self.new(primitive, options)
          member_types = options.
            fetch(:member_types).
            each_with_object({}) { |(k, t), res| res[k] = t.safe }

          super(primitive, options.merge(member_types: member_types))
        end

        # @param [Hash] hash
        # @param [#call] block
        # @yieldparam [Failure] failure
        # @yieldreturn [Result]
        # @return [Result]
        def try(hash, &block)
          if hash.is_a?(::Hash)
            super
          else
            result = failure(hash, "#{hash} must be a hash")
            block ? yield(result) : result
          end
        end
      end

      # {Symbolized} hash will turn string key names into symbols.
      class Symbolized < Weak
        private


        def resolve(hash)
          result = {}

          ignored_values = (hash.keys.map(&:to_sym) - member_types.keys).inject({}) do |ignored_data,k|
            ignored_data[k] = hash[k]
            ignored_data
          end

          member_types.each do |key, type|
            keyname =
              if hash.key?(key)
                key
              elsif hash.key?(string_key = key.to_s)
                string_key
              end

            if keyname
              result[key] = yield(type, key, hash[keyname])
            else
              resolve_missing_value(result, key, type)
            end
          end
          [result,ignored_values]
        end
      end

      private_constant(*constants(false))
    end
  end
end
