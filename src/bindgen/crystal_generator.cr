module Bindgen
  # Generator for Crystal code of the bound library.  This includes the
  # low-level bindings to the wrapped library, but also the user-facing wrapper
  # classes.
  class CrystalGenerator < Generator
    include CallAnalyzer::CrystalMethods
    INDENTION = "  "

    # Base class of sequential containers
    SEQUENTIAL_BASECLASS = "BindgenHelper::SequentialContainer"

    # Base class of associative containers
    ASSOCIATIVE_BASECLASS = "BindgenHelper::AssociativeContainer"

    # Generic argument for a `CrystalProc`, defined in `Binding::`
    CRYSTAL_PROC_TYPE = "CrystalProc"

    def initialize(@db : TypeDatabase, @io : IO)
      @depth = 0
      @external_types = Set(String).new
      @lib_types = Set(String).new
      @lib_methods = { } of Parser::Method => Parser::Type
      @classes = { } of String => Parser::Class
      @last_classes = { } of String => Parser::Class
      @enums = [ ] of Parser::Enum
      @external_sub_class = { } of String => String

      # Binding for Qt signals.  Unused otherwise.
      @external_types << "QMetaObject::Connection" << "CrystalProc"
    end

    # Enters a code block starting with *header* and increasing the indention
    # depth temporarily during the `yield`.
    def block(*header)
      print header.join(" ")
      @depth += 1
      yield
      @depth -= 1
      print "end"
    end

    # Like `#block`, but with support for a `lib` block.
    def lib_block(name, ld_flags : String?)
      print %<@[Link(ldflags: "#{ld_flags}")]> if ld_flags
      block "lib", name do
        yield
      end
    end

    # Prints the header comment telling the user to leave the file alone.
    def print_header
      @io.puts "# GENERATED CODE - DO NOT CHANGE"
      @io.puts "#   Generated by bindgen.cr"
      @io.puts "#   Time: #{Time.now}"
      @io.puts "# See: https://github.com/Papierkorb/bindgen"
      @io.puts ""
    end

    # Prints verbatim, but indented, *data* into the output.
    def print(data)
      @io.puts indent(data) if data
    end

    # Stores an *enumeration* to be wrapped later on.
    def add_enumeration(enumeration : Parser::Enum)
      @external_types << enumeration.name
      @enums << enumeration
    end

    # Writes an *enumeration* wrapper into the output.
    def write_enumeration(enumeration : Parser::Enum)
      backing_type_name = enumeration.name
      if backing_type = @db[enumeration.type]?
        backing_type_name = backing_type.crystal_type || backing_type.binding_type
      end

      enum_name = @db.try_or(enumeration.name, enumeration.name, &.crystal_type)
      # Remove name-qualification
      enum_name = enum_name.sub(/.*::/, "")

      print "@[Flags]" if enumeration.flags?
      block "enum", enum_name, ":", backing_type_name do
        enumeration.values.each do |key, value|
          print "#{key.camelcase} = #{value}"
        end
      end
    end

    # Stores a *klass* to be wrapped later on.
    def add_class(klass : Parser::Class, last = false)
      if last
        @last_classes[klass.name] = klass
      else
        @classes[klass.name] = klass
      end

      klass_type = klass.as_type(pointer: 1)

      # Support for classes without constructors:
      add_binding_type klass_type

      unless @db.try_or(klass.name, true, &.generate_wrapper)
        return # The user wants to write manual bindings.
      end

      klass.wrap_methods.each do |method|
        add_method?(method, klass_type)
      end

      add_method?(klass.destructor_method, klass_type)
      add_as_other_type_bindings(klass, klass_type)
    end

    # Adds *container* to be wrapped.
    def add_container(container : Configuration::Container)
      if container.type.sequential?
        container.instantiations.each do |args|
          next if args.size != 1
          add_sequential_container_class(container, args)
        end
      end
    end

    # Adds the class necessary to wrap the sequential *container* in the given
    # *instantiation*.
    private def add_sequential_container_class(container, instantiation)
      type_name = instantiation.first
      var_type = Parser::Type.parse(type_name)

      klass = build_sequential_container_class(container, var_type)
      base_class = container_baseclass(container, instantiation)

      klass.bases << base_class # Our glue container.
      @external_sub_class[klass.name] = base_class.name

      cpp_type_name = container_cpp_type_name(container, instantiation)
      set_sequential_container_type_rules(cpp_type_name, klass, var_type)

      add_class(klass, last: true)
      @external_types << cpp_type_name
    end

    # Updates the *rules* of the container *klass*, carrying a *var_type*.
    # The rules are changed to convert from and to the binding type.
    private def set_sequential_container_type_rules(cpp_type_name, klass, var_type)
      rules = @db.get_or_add(cpp_type_name)
      result = pass_to_wrapper(var_type)

      rules.binding_type = "Void"
      rules.crystal_type ||= "Enumerable(#{result.type_name})"
      rules.to_crystal ||= "#{klass.name}.new(unwrap: %)"
      rules.from_crystal ||= "BindgenHelper.wrap_container(#{klass.name}, %)"
    end

    # Computes the base-class of the wrapper-class.
    private def container_baseclass(container, instantiation) : Parser::BaseClass
      if container.type.sequential?
        var_type = Parser::Type.parse(instantiation.first)
        type_name = qualified_wrapper_typename(var_type)
        class_name = "#{SEQUENTIAL_BASECLASS}(#{type_name})"

        Parser::BaseClass.new(name: class_name)
      else
        raise "no associative container support yet"
      end
    end

    # Stores *method* to the `lib` bindings if it's not
    # `Parser::Method#filtered?`.
    private def add_method?(method : Parser::Method, type)
      unless method.filtered?(@db)
        @lib_methods[method] = type
        add_method_types(method)
      end
    end

    # Registers all types in *method*, so that the correct `alias`es to `Void`
    # can be generated later on in the bindings `lib` block.
    def add_method_types(method : Parser::Method)
      add_binding_type method.return_type

      method.arguments.each do |arg|
        add_binding_type arg
      end
    end

    # Registers *type*, so that the correct `alias`es to `Void`
    # can be generated later on in the bindings `lib` block.
    def add_binding_type(type)
      return if type.builtin?
      return if @external_types.includes?(type.base_name)
      @lib_types << type.base_name
    end

    # Writes the C bindings code.  It is expected to be run in a `#lib_block` of
    # name `Binding`.
    def emit_bindings
      copy_structures = [ ] of String

      @lib_types.each do |type|
        # Only write an `alias X = Void` if we don't copy the structure.
        if @db.try_or(type, false, &.copy_structure)
          copy_structures << type
        else
          print "alias #{type} = Void"
        end
      end

      # Copy structures of those types requested
      copy_structures.each do |name|
        write_structure(@classes[name])
      end

      @io.puts ""
      (@classes.values + @last_classes.values).each do |klass|
        unless @db.try_or(klass.name, true, &.generate_binding)
          next # The user wants to write manual bindings.
        end

        if is_class_subclassed?(klass)
          write_subclass_table(klass)
          write_virtual_subclass_setter(klass)
        end
      end

      @io.puts ""
      @lib_methods.each do |method, type|
        unless @db.try_or(method.class_name, true, &.generate_binding)
          next # The user wants to write manual bindings.
        end

        write_method_binding(method, type)
        write_signal_connect_binding(method, type) if method.signal?
      end
    end

    # Writes a `lib struct` of all fields in *klass*.
    private def write_structure(klass : Parser::Class)
      struct_name = @db.try_or(klass.name, klass.name, &.lib_type)
      block "struct", struct_name do
        klass.fields.each_with_index do |field, idx|
          result = pass_to_binding(field)
          var_name = argument_name(field.crystal_name, idx)

          print "#{var_name} : #{result.type_name}"
        end
      end
    end

    # Adds a `fun` binding from *klass* to all of its wrapped base-classes,
    # except for the first one.
    private def add_as_other_type_bindings(klass : Parser::Class, type)
      wrapped_base_classes_of(klass, range: 1..-1).each do |base|
        method = as_other_type_method(klass, base)
        add_method? method, type
      end
    end

    # Writes the sub-class method table.  The Crystal equivalent to `CppGenerator#write_redirection_table`.
    private def write_subclass_table(klass : Parser::Class)
      table_name = subclass_table_name(klass)
      redirected_methods = unique_virtual_methods(klass)

      block "struct", table_name do
        redirected_methods.each do |_, method|
          print "#{method.mangled_name} : #{CRYSTAL_PROC_TYPE}"
        end
      end
    end

    # Same as its equivalent in `CppGenerator`.
    private def write_virtual_subclass_setter(klass)
      func_name = class_jumptable_setter_name(klass)
      func_args = [
        "self : #{with_pointer klass.name}",
        "table : #{with_pointer subclass_table_name(klass)}"
      ]

      fun_decl = generate_fun_declaration(func_name, func_args, "Void")
      print fun_decl
    end

    # Generates the binding to the `_CONNECT` shadow method of a signal method.
    private def write_signal_connect_binding(method : Parser::Method, type)
      conn_method, _ = generate_signal_connect_binding_method(method)
      write_method_binding(conn_method, type)
    end

    # Writes lib binding for *method* from class *type*.
    private def write_method_binding(method : Parser::Method, type)
      analyzer = CallAnalyzer::CrystalBinding.new(@db)
      generator = CallGenerator::CrystalFun.new

      call = analyzer.analyze(method, type)
      print generator.generate(call)
    end

    # Generates the `fun` declaration using bare type names.
    private def generate_fun_declaration(name : String, arguments : Array(String), return_type : String)
      %<fun #{name}(#{arguments.join(", ")}) : #{return_type}>
    end

    # Writes the Crystal class wrappers into the output.
    def emit_wrappers
      # Write top-level enumerations
      write_enumerations_where{|name| !name.includes?("::")}

      (@classes.values + @last_classes.values).each do |klass|
        unless @db.try_or(klass.name, true, &.generate_wrapper)
          next # The user wants to write manual bindings.
        end

        write_class_wrapper(klass)
        write_abstract_class_impl_wrapper(klass) if klass.abstract?
      end
    end

    # Writes all registered enumerations for which the given block returns
    # truthy.
    private def write_enumerations_where
      @enums.each do |enumeration|
        name = @db.try_or(enumeration.name, enumeration.name, &.crystal_type)
        write_enumeration(enumeration) if yield(name)
      end
    end

    # Writes a wrapper for *klass* into the output.
    private def write_class_wrapper(klass : Parser::Class)
      crystal_class = crystal_class_name(klass)

      base_class = find_wrapped_base_class(klass)
      if base_class
        name = @db.try_or(base_class.name, base_class.name, &.crystal_type)
        suffix = "< #{name}"
      elsif name = @external_sub_class[klass.name]?
        # Support for forced externally defined sub-class if no other type was
        # sensible.
        suffix = "< #{name}"
      end

      prefix = "class" # Handle abstract classes!
      prefix = "abstract class" if klass.abstract?

      block prefix, crystal_class, suffix do
        qualified_prefix = "#{crystal_class}::"
        write_enumerations_where(&.starts_with?(qualified_prefix))

        if base_class.nil?
          write_class_unwrap_definition
          write_class_to_unsafe_method
        end

        write_class_unwrap_initializer(klass)
        write_as_other_type_wrappers(klass)

        klass.wrap_methods.each do |method|
          next if method.filtered?(@db)
          write_method_wrapper(klass, method, abstract_pure: true)
          write_signal_connect_wrapper(klass, method) if method.signal?
        end
      end
    end

    # Writes a class implementation of the abstract class *klass*, inheriting
    # it, and only implementing pure virtual methods.
    #
    # This implementation class is required for `#as_X` methods converting to
    # an abstract class.
    private def write_abstract_class_impl_wrapper(klass : Parser::Class)
      base_class = crystal_class_name(klass)
      crystal_class = impl_class_name(klass)

      block "class", crystal_class, "< #{base_class}" do
        write_disable_inheritance("You can't sub-class #{crystal_class}, inherit from #{base_class} instead")

        klass.wrap_methods.each do |method|
          next if method.filtered?(@db)
          next unless method.pure?
          write_method_wrapper(klass, method, abstract_pure: false)
        end
      end
    end

    # Writes an `inherited` Crystal hook, which raises *message*.  This is used
    # by the abstract-class implementation class as this would allow to not
    # implement all abstract methods.
    private def write_disable_inheritance(message : String)
      print "macro inherited"
      print "  {{ raise #{message.inspect} }}"
      print "end"
    end

    # Returns the shadow-implementation class name for the abstract class
    # *klass*.
    private def impl_class_name(klass : Parser::Class | String)
      "#{crystal_class_name klass}Impl"
    end

    # Returns the name of *klass* as used in user-facing code.
    private def crystal_class_name(klass : Parser::Class) : String
      @db.try_or(klass.name, klass.name, &.crystal_type)
    end

    # Writes all `#as_X` wrappers for *klass*.
    private def write_as_other_type_wrappers(klass : Parser::Class)
      wrapped_base_classes_of(klass, range: 1..-1).each do |base|
        method = as_other_type_method(klass, base)
        write_method_wrapper(klass, method)
      end
    end

    # Builds a `#as_X` user-facing wrapper method.
    private def as_other_type_method(klass : Parser::Class, target : Parser::Class) : Parser::Method
      target_name = pass_from_wrapper(target.as_type).type_name.underscore

      method = build_method(
        name: klass.converter_name(target),
        class_name: klass.name,
        return_type: target.as_type,
        arguments: [ ] of Parser::Argument,
        crystal_name: "as_#{target_name}",
      )
    end

    # Writes the connect method for the signal in *method*.  The user can then
    # pass a block to the generated method of name `on_NAME` to connect.
    # Hopefully a `btn.on_pressed do .. end` reading nicer than
    # `btn.pressed do .. end` is worth the confusion.
    private def write_signal_connect_wrapper(klass, method : Parser::Method)
      # block_type = proc_type(Parser::Type::VOID, method.arguments)
      conn_method, proc_method = generate_signal_connect_binding_method(method)

      binding = CallAnalyzer::CrystalBinding.new(@db)
      reverse = CallAnalyzer::CrystalReverseBinding.new(@db)
      wrapper = CallAnalyzer::CrystalWrapper.new(@db)
      to_proc = CallAnalyzer::CppToCrystalProc.new(@db)
      proc_gen = CallGenerator::CrystalProcType.new
      wrapper_gen = CallGenerator::CrystalWrapper.new
      lambda_gen = CallGenerator::CrystalLambda.new

      binding_call = binding.analyze(conn_method, klass.as_type)
      block_call = reverse.analyze(method, nil)
      wrapper_call = wrapper.analyze(conn_method)
      block_invoke = wrapper.analyze(proc_method, instance_name: "block")

      # The wrapper shall expect a Crystal block with the arguments of the
      # signal method itself.
      block_arg = Call::ProcResult.new(
        method: method,
        type_name: proc_gen.generate(block_invoke)
      ).to_argument(name: "block", block: true)

      wrapper_call.arguments.clear # HACK
      wrapper_call.arguments << block_arg

      # We call from the WRAPPER to the BINDING, except that we're passing
      # a proc to it calling from C++ to Crystal.  Basically, a duplicate
      # wrapper going both directions.  Which is why this method is complex.
      code = wrapper_gen.generate(wrapper_call, binding_call) do |pass_args|
        arg = lambda_gen.generate(block_call, block_invoke, wrap: true)
        wrapper_gen.invocation({ binding_call, wrapper_call }, [ "self", arg ])
      end

      print code
    end

    # Finds the first base class for *klass* which is wrapped, if any.
    private def find_wrapped_base_class(klass : Parser::Class) : Parser::Class?
      wrapped_base_classes_of(klass) do |found|
        return found
      end

      nil
    end

    # Writes the `@unwrap` variable definition for a class wrapper.
    private def write_class_unwrap_definition
      print "@unwrap : Void*"
    end

    # Writes the `#to_unsafe` method implementation for a class wrapper.
    private def write_class_to_unsafe_method
      print %{def to_unsafe\n  @unwrap\nend}
    end

    # Writes the `#initialize` method directly setting `@unwrap`.
    # This fixes an issue with `@unwrap` never being initialized in all
    # `#initialize` if there aren't any initializers.
    private def write_class_unwrap_initializer(klass)
      block "def", "initialize(@unwrap : Void*)" do
      end
    end

    # Generates the jump-table initialization process, which is copied into
    # every `#initialize` of a sub-classed class.  This involves first, creating
    # the jump-table, and then using the `JUMPTABLE` binding to actually set
    # the table in the target.
    #
    # Note: The jump-table is copied in C++-land, thus we can just pass it a
    # pointer (C++ accepts it as a reference).
    #
    # Note²: This generates macro-code, which will evaluate at compile-time.
    # Downside is, this slows down compilation even if no method is overwritten.
    #
    # TODO: Support for overloaded virtual methods!
    private def generate_virtual_table_initialization(klass : Parser::Class) : String
      table_type = subclass_table_name(klass)
      setter_func = class_jumptable_setter_name(klass)
      methods = unique_virtual_methods(klass)

      String.build do |b|
        b << "{% begin %}\n"

        # Generates the `forwarded` macro variable
        b << generate_initialize_virtual_methods_macro(klass, methods)

        # Build the table
        b << "jump_table = Binding::#{table_type}.new(\n"

        methods.each do |method_class, method|
          name = method.crystal_name
          functor = generate_call_in_lambda("self", method)
          b << "  #{method.mangled_name}: BindgenHelper.wrap_proc({% if forwarded.includes?(#{name.inspect}) %} #{functor} {% else %} nil {% end %}),\n"
        end

        b << ")\n"

        # Call the JUMPTABLE set function
        b << "Binding.#{setter_func} unwrap, pointerof(jump_table)\n"
        b << "{% end %}\n"
      end
    end

    # Generates a string calling the *method* on *instance_name* in a
    # stabby-lambda.  The call will convert from C++ to Crystal and back.
    #
    # Important: This lambda expects to be called from C++-land, and calls into
    # Crystal-land!
    private def generate_call_in_lambda(instance_name, method : Parser::Method) : String
      binding = CallAnalyzer::CrystalReverseBinding.new(@db)
      wrapper = CallAnalyzer::CrystalWrapper.new(@db)
      lambda_gen = CallGenerator::CrystalLambda.new

      binding_call = binding.analyze(method, klass_type: nil)
      wrapper_call = wrapper.analyze(method, instance_name)

      lambda_gen.generate(binding_call, wrapper_call)
    end

    # Generates a piece of macro code, to be evaluated by the Crystal compiler
    # at compile-time of the user application, which gathers all overwritten
    # virtual methods into the `forwarded` macro variable.
    private def generate_initialize_virtual_methods_macro(klass, methods) : String
      crystal_name = crystal_class_name(klass)
      # TODO: Support for overloaded virtual methods:
      names = methods.map(&.last.crystal_name).join(" ")

      String.build do |b|
        b << %[{%\n]
        b << %[  methods = [] of Def\n]
        b << %[  ([@type] + @type.ancestors).select(&.<(#{crystal_name})).map{|x| methods = methods + x.methods}\n]
        b << %[  forwarded = methods.map(&.name.stringify).select{|m| %w[ #{names} ].includes?(m) }.uniq\n]
        b << %[%}\n]
      end
    end

    # Writes a the user-facing wrapper for *method* in *klass*.  Setting
    # *abstract_pure* to `false` forces an implementation, regardless if
    # *method* is pure or not.  Otherwise, for a pure *method*, only an
    # `abstract def` will be written.
    private def write_method_wrapper(klass : Parser::Class, method : Parser::Method, abstract_pure = true)

      binding = CallAnalyzer::CrystalBinding.new(@db)
      wrapper = CallAnalyzer::CrystalWrapper.new(@db)

      # Mark pure methods as such in Crystal.
      if abstract_pure && method.pure?
        wrapper_gen = CallGenerator::CrystalAbstractWrapper.new
      else
        wrapper_gen = CallGenerator::CrystalWrapper.new
      end

      binding_call = binding.analyze(method, klass.as_type(pointer: 1))
      wrapper_call = wrapper.analyze(method)

      # Generate the code
      if is_class_subclassed?(klass)
        body = generate_virtual_table_initialization(klass)
      end

      print wrapper_gen.generate(wrapper_call, binding_call, body)
    end

    # Indents *str* according to the current indention level.  *str* can be
    # multi-line.
    private def indent(str : String) : String
      prefix = INDENTION * @depth
      prefix + str.gsub("\n", "\n#{prefix}")
    end

    # Name of the generated function-pointer table struct for *klass*.
    private def subclass_table_name(klass : String | Parser::Class) : String
      klass = klass.name if klass.is_a?(Parser::Class)
      "BgTable#{klass}"
    end
  end
end
