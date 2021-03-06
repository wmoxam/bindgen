module Bindgen
  module CallAnalyzer
    # Helper methods useful for all call analyzers.
    module Helper
      extend self

      # Builds a result passing-through *type* without modifications.
      def passthrough(type : Parser::Type)
        Call::Result.new(
          type: type,
          type_name: type.base_name,
          reference: type.reference?,
          pointer: type_pointer_depth(type),
          conversion: nil,
        )
      end

      # Returns the pointer-depth without a reference of *type*.
      def type_pointer_depth(type : Parser::Type) : Int32
        depth = type.pointer
        depth -= 1 if type.reference?
        { depth, 0 }.max
      end

      # Is *type* available in Crystal?  It will be if any of:
      # 1. The structure will be copied
      # 2. It's a built-in type
      # 3. It's an enumeration type
      #
      # Otherwise, `false` is returned.  If the *type* is not configured in the
      # type database, it defaults to `false`.
      def is_type_copied?(type) : Bool
        if rules = @db[type]?
          rules.copy_structure || rules.builtin || rules.kind.enum?
        else
          false
        end
      end

      # Helper for `#pass_to_X`, configuring the type according to
      # user-specified rules.
      def reconfigure_pass_type(pass_by, is_ref, ptr)
        if pass_by.reference? && !is_ref
          is_ref = true
          ptr -= 1 if ptr > 0
        elsif pass_by.pointer?
          is_ref = false
          ptr += 1
        elsif pass_by.value?
          ptr -= 1 if ptr > 0
          is_ref = false
        end

        { is_ref, ptr }
      end
    end
  end
end
