require "../syntax/parser"
require "./hooked_exceptions"
require "./types/function"
require "./types/class"
require "./types/type"
require "./scope"
require "./operator"
require "./resolver"
require "./intrinsic/number"
require "./intrinsic/string"
require "./intrinsic/vector"
require "./intrinsic/lib/math"

class Cosmo::Interpreter
  include Expression::Visitor(ValueType)
  include Statement::Visitor(ValueType)

  private alias MetaType = String | ClassInstance

  getter globals = Scope.new
  getter scope : Scope
  getter meta = {} of String => MetaType
  @locals = {} of Expression::Base => UInt32
  @file_path : String = ""
  @importable_intrinsics = {} of String => IntrinsicLib
  @loop_level : UInt32 = 0

  def initialize(
    @output_ast : Bool,
    @run_benchmarks : Bool,
    @debug_mode : Bool
  )
    Logger.debug = debug_mode
    TypeChecker.register_intrinsics

    @scope = @globals
    declare_intrinsic("func", "puts", PutsIntrinsic.new(self))
    declare_intrinsic("func", "gets", GetsIntrinsic.new(self))

    version = "Cosmo #{Version}"
    declare_intrinsic("string", "version$", version)

    declare_importable("math", MathLib.new(self))
  end

  private def declare_importable(name : String, library : IntrinsicLib)
    @importable_intrinsics[name] = library
  end

  def fake_typedef(name : String, location : Location? = nil)
    Token.new(name, Syntax::TypeDef, name, location || Location.new(@file_path, 0, 0))
  end

  def fake_ident(name : String, location : Location? = nil)
    Token.new(name, Syntax::Identifier, name, location || Location.new(@file_path, 0, 0))
  end

  def declare_intrinsic(type : String, ident : String, value : ValueType)
    location = Location.new("intrinsic", 0, 0)
    ident_token = fake_ident(ident, location)
    typedef_token = fake_typedef(type, location)
    @globals.declare(typedef_token, ident_token, value, const: true)
  end

  def delete_meta(key : String) : Nil
    @meta.delete(key)
  end

  def set_meta(key : String, value : MetaType?) : Nil
    return if value.nil?
    @meta[key] = value
  end

  def interpret(source : String, @file_path : String) : ValueType
    parser = Parser.new(source, @file_path, @run_benchmarks)
    statements = parser.parse

    statement_list_str = ""
    statements.each do |stmt|
      statement_list_str += stmt.to_s + "\n"
    end

    puts statement_list_str if @output_ast

    resolver = Resolver.new(self)
    resolver.resolve(statements)
    end_time = Time.monotonic
    puts "Resolver @#{@file_path} took #{get_elapsed(resolver.start_time, end_time)}." if @run_benchmarks

    start_time = Time.monotonic

    result = nil
    statements.each do |stmt|
      result = execute(stmt)
    end

    # Check if "main" fn exists and call it
    main_fn = @globals.lookup?("main")
    is_public = @globals.public?("main")
    found_main = !main_fn.nil? && main_fn.is_a?(Function)
    if found_main
      if is_public
        main_fn = main_fn.as(Function)
        return_typedef = main_fn.return_typedef
        unless TypeChecker.is?(return_typedef.lexeme, 1, return_typedef) # it's an integer
          Logger.report_error("Invalid main() function", "A main() function may only return 'int'", return_typedef)
        end

        main_result = main_fn.call([ARGV.map(&.as ValueType)])
        TypeChecker.assert("int", main_result, return_typedef)
      else
        puts "[WARNING]: Found main() function, but it is not public. It will not be called on program execution."
      end
    end

    end_time = Time.monotonic
    puts "Interpreter @#{file_path} took #{get_elapsed(start_time, end_time)}." if @run_benchmarks

    if found_main && @file_path != "test" && @file_path != "repl"
      code = main_result.not_nil!.as(Int64)
      if code == 0 # success
        Process.exit(code)
      else
        raise "Process exited with code #{code}"
      end
    end

    result
  end

  def resolve(expr : Expression::Base, depth : UInt32) : Nil
    @locals[expr] = depth
  end

  private def lookup_variable(identifier : Token, expr : Expression::Base) : ValueType
    distance : UInt32? = @locals[expr]?
    return @scope.lookup_at(distance, identifier) unless distance.nil?
    @globals.lookup(identifier)
  end

  def evaluate(expr : Expression::Base) : ValueType
    expr.accept(self)
  end

  def execute(stmt : Statement::Base) : ValueType
    stmt.accept(self)
  end

  def execute_block(block : Statement::Base, block_scope : Scope, is_fn : Bool = false) : ValueType
    enclosing = @scope
    begin
      @scope = block_scope

      unless @meta["this"]?.nil? || !@scope.lookup?("$").nil?
        this = @meta["this"].as(ClassInstance)
        @scope.declare(
          fake_typedef(this.name),
          fake_ident("$"),
          this
        )
      end

      if block.is_a?(Statement::Block)
        unless block.nodes.empty?
          return_node = block.nodes.find { |node| node.is_a?(Statement::Return) } || block.nodes.last
          body_nodes = block.nodes[0..-2]
          body_nodes.each { |stmt| execute(stmt) }
          return_value = execute(return_node) unless return_node.nil?
        end
        if is_fn
          return_type = @meta["block_return_type"]
          token = return_node.nil? ? Token.new("none", Syntax::None, nil, Location.new("", 0, 0)) : return_node.token
          unless return_type.to_s == "void"
            TypeChecker.assert(return_type.to_s, return_value, token)
          end
        end
      else
        return_value = execute(block)
      end

      return return_value unless return_type.to_s == "void"
      nil
    rescue ex : Exception
      raise ex
    ensure
      @scope = enclosing
    end
  end

  private def import_file(path : String) : Nil
    # TODO: import main file if directory

    source = File.read(path)
    enclosing = @scope
    module_scope = Scope.new(@scope)

    interpret(source, path)
    globals.extend(module_scope)

    @scope = enclosing
  end

  def visit_use_stmt(stmt : Statement::Use) : Nil
    relative_module_path = stmt.module_path.lexeme
    unless relative_module_path.includes?("/")
      unless @importable_intrinsics.has_key?(relative_module_path)
        file_path = File.join File.dirname(__FILE__), "../../../libraries", relative_module_path
        full_path = File.exists?(file_path + ".cos") ? file_path + ".cos" : file_path + ".⭐"
        if File.exists?(full_path)
          import_file(full_path)
        else
          Logger.report_error("Invalid import", "No package management system implemented yet. If you are trying to import a file path, prepend './' to the path.", stmt.module_path)
        end
      else
        @importable_intrinsics[relative_module_path].inject
      end
    else
      if @file_path == "repl"
        Logger.report_error("Cannot import", "Non-package modules are not supported in the REPL", stmt.module_path)
      end

      full_module_path = File.join File.dirname(@file_path), relative_module_path
      ext_file_path = File.exists?(full_module_path + ".cos") ? full_module_path + ".cos" : full_module_path + ".⭐"
      if full_module_path.includes?("././")
        Logger.report_error("Recursive import detected", ext_file_path.gsub("./", ""), stmt.module_path)
      end

      module_path = ext_file_path.gsub("./", "")
      unless File.exists?(ext_file_path)
        Logger.report_error("Invalid import", "No such file '#{module_path}.cos/⭐' exists", stmt.module_path)
      end

      import_file(ext_file_path)
    end
  end

  def visit_case_stmt(stmt : Statement::Case) : ValueType
    value = evaluate(stmt.value)
    go_to_else = false

    stmt.comparisons.each do |when_stmt|
      condition = true
      when_stmt.conditions.each do |condition_expr|
        if condition_expr.is_a?(Expression::TypeRef)
          condition &= TypeChecker.is?(condition_expr.name.lexeme, value, when_stmt.token)
        else
          condition &= evaluate(condition_expr) == value
        end
      end

      return execute(when_stmt.block) if condition
      go_to_else = true
    end

    return execute(stmt.else.not_nil!) if !stmt.else.nil? && go_to_else
  end

  def visit_throw_stmt(stmt : Statement::Throw) : Nil
    err = evaluate(stmt.err)
    unless TypeChecker.is?("string", err, stmt.token)
      Logger.report_error("Throw statement can only be invoked with a string currently, got", TypeChecker.get_mapped(err.class), stmt.token)
    end

    # TODO: stack traces & error levels
    Logger.report_error("Error", err.to_s, stmt.token)
  end

  def visit_next_stmt(stmt : Statement::Next) : Nil
    raise HookedExceptions::Next.new(stmt.keyword, @loop_level)
  end

  def visit_break_stmt(stmt : Statement::Break) : Nil
    raise HookedExceptions::Break.new(stmt.keyword, @loop_level)
  end

  def visit_return_stmt(stmt : Statement::Return) : Nil
    value = evaluate(stmt.value)
    raise HookedExceptions::Return.new(value, stmt.keyword)
  end

  def visit_until_stmt(stmt : Statement::Until) : Nil
    @loop_level += 1
    until evaluate(stmt.condition)
      begin
        execute(stmt.block)
      rescue _break : HookedExceptions::Break
        break if @loop_level == _break.loop_level
      rescue _next : HookedExceptions::Next
        next if @loop_level == _next.loop_level
      end
    end
  end

  def visit_while_stmt(stmt : Statement::While) : Nil
    @loop_level += 1
    while evaluate(stmt.condition)
      begin
        execute(stmt.block)
      rescue _break : HookedExceptions::Break
        break if @loop_level == _break.loop_level
      rescue _next : HookedExceptions::Next
        next if @loop_level == _next.loop_level
      end
    end
  end

  def visit_every_stmt(stmt : Statement::Every) : Nil
    enclosing = @scope
    @scope = Scope.new(@scope)

    enumerable = evaluate(stmt.enumerable)
    @scope.declare(stmt.var.typedef, stmt.var.token, nil)

    @loop_level += 1
    if enumerable.is_a?(Array) || enumerable.is_a?(Range)
      enumerable.each do |value|
        @scope.assign(stmt.var.token, value)
        begin
          execute_block(stmt.block, scope)
        rescue _break : HookedExceptions::Break
          break if @loop_level == _break.loop_level
        rescue _next : HookedExceptions::Next
          next if @loop_level == _next.loop_level
        end
      end
    elsif enumerable.is_a?(String)
      enumerable.chars.each do |value|
        @scope.assign(stmt.var.token, value)
        begin
          execute_block(stmt.block, scope)
        rescue _break : HookedExceptions::Break
          break if @loop_level == _break.loop_level
        rescue _next : HookedExceptions::Next
          next if @loop_level == _next.loop_level
        end
      end
    elsif enumerable.is_a?(Callable)
      if enumerable.is_a?(IntrinsicFunction)
        Logger.report_error("Invalid iterator", "An iterator cannot be an intrinsic function", stmt.enumerable.token)
      end
      unless enumerable.is_a?(Function)
        Logger.report_error("Invalid iterator", "An iterator must return a generator function", stmt.enumerable.token)
      end

      # keep looping until the iterator returns none
      until (value = enumerable.call([] of ValueType)).nil?
        @scope.assign(stmt.var.token, value)
        begin
          execute_block(stmt.block, scope)
        rescue _break : HookedExceptions::Break
          break if @loop_level == _break.loop_level
        rescue _next : HookedExceptions::Next
          next if @loop_level == _next.loop_level
        end
      end
    else
      Logger.report_error("Invalid iterator type", TypeChecker.get_mapped(enumerable.class), stmt.token)
    end

    @scope = enclosing
  end

  def visit_unless_stmt(stmt : Statement::Unless) : ValueType
    condition = evaluate(stmt.condition)
    unless condition
      execute(stmt.then)
    else
      execute(stmt.else.not_nil!) unless stmt.else.nil?
    end
  end

  def visit_if_stmt(stmt : Statement::If) : ValueType
    condition = evaluate(stmt.condition)
    if condition
      execute(stmt.then)
    else
      execute(stmt.else.not_nil!) unless stmt.else.nil?
    end
  end

  def visit_class_def_stmt(stmt : Statement::ClassDef) : ValueType
    _class = Class.new(self, @scope, stmt)
    unless @scope.lookup?(stmt.identifier.lexeme).nil?
      Logger.report_error("Cannot redefine class", "Class #{stmt.identifier.lexeme} is already defined.", stmt.identifier)
    end

    @scope.declare(
      fake_typedef("class"),
      stmt.identifier,
      _class,
      const: true,
      visibility: stmt.visibility
    )
  end

  def visit_fn_def_stmt(stmt : Statement::FunctionDef) : ValueType
    if @meta["this"]?.nil?
      @scope.declare(
        fake_typedef("func"),
        stmt.identifier,
        Function.new(self, @scope, stmt),
        const: true,
        visibility: stmt.visibility
      )
    else
      instance = @meta["this"].as ClassInstance
      instance.define_method(
        stmt.identifier.lexeme,
        Function.new(self, @scope, stmt, instance),
        token: stmt.token,
        visibility: stmt.visibility
      )
    end
  end

  def visit_lambda_expr(expr : Expression::Lambda) : ValueType
    Function.new(self, @scope, expr)
  end

  def visit_access_expr(expr : Expression::Access) : ValueType
    object = evaluate(expr.object)
    key = expr.key.lexeme

    if object.is_a?(Hash)
      value = object[key]?
      if value.nil?
        Logger.report_error("Invalid table key", "'#{key}'", expr.key)
        # redirect to hash intrinsic methods, else error
      end
      value
    elsif object.is_a?(Array)
      VectorIntrinsics.new(self, object)
        .get_method(expr.key)
    elsif object.is_a?(String)
      StringIntrinsics.new(self, object)
        .get_method(expr.key)
    elsif object.is_a?(Number)
      NumberIntrinsics.new(self, object)
        .get_method(expr.key)
    elsif object.is_a?(ClassInstance)
      object.get_member(key, expr.key, include_private: !@meta["this"]?.nil?)
    else
      Logger.report_error("Attempt to index", TypeChecker.get_mapped(object.class), expr.token)
    end
  end

  def visit_index_expr(expr : Expression::Index) : ValueType
    object = evaluate(expr.object)
    key = evaluate(expr.key)

    if object.is_a?(String) || object.is_a?(Array)
      unless key.is_a?(Int) || key.is_a?(Range)
        Logger.report_error("Invalid index type", TypeChecker.get_mapped(key.class), expr.key.token)
      end

      value = object[key]?
      if value.nil? && !expr.nullable
        Logger.report_error("Index out of bounds", "Index #{key}, array size #{object.size}", expr.key.token)
      end
      value
    elsif object.is_a?(Hash)
      value = object[key]?
      if value.nil?
        Logger.report_error("Invalid table key", "'#{key}'", expr.key.token)
      end
      value
    elsif object.is_a?(ClassInstance)
      Logger.report_error("Attempt to index class instance", expr.token.lexeme, expr.token)
    else
      Logger.report_error("Attempt to index", TypeChecker.get_mapped(object.class), expr.token)
    end
  end

  def visit_new_expr(expr : Expression::New) : ClassInstance
    args = [] of Expression::Base
    class_obj = @scope.lookup(expr.operand.token)
    unless class_obj.is_a?(Class)
      Logger.report_error("Invalid 'new' invocation. Expected a class name, got", expr.operand.token.lexeme, expr.operand.token)
    end
    if expr.operand.is_a?(Expression::FunctionCall)
      args = expr.operand.as(Expression::FunctionCall).arguments
    end

    TypeChecker.assert("class", class_obj, expr.operand.token)
    class_obj.construct(args.map { |arg| evaluate(arg) })
  end

  def visit_this_expr(expr : Expression::This) : ValueType
    @scope.lookup?("$")
  end

  def visit_cast_expr(expr : Expression::Cast) : ValueType
    value = evaluate(expr.value)
    TypeChecker.cast(value, expr.type.name)
  end

  def visit_is_expr(expr : Expression::Is) : Bool
    value = evaluate(expr.value)
    TypeChecker.is?(expr.type.name.lexeme, value, expr.token)
  end

  def visit_type_ref_expr(expr : Expression::TypeRef) : Type
    TypeChecker.get_registered_type(expr.name.value.to_s, expr.name)
  end

  def visit_type_alias_expr(expr : Expression::TypeAlias) : Nil
    value = evaluate(expr.value)
    @scope.declare(expr.type_token, expr.token, value, expr.constant?, expr.visibility)
  end

  def visit_fn_call_expr(expr : Expression::FunctionCall) : ValueType
    fn = evaluate(expr.callee)
    unless fn.is_a?(Function) || fn.is_a?(IntrinsicFunction)
      Logger.report_error("Attempt to call", fn.is_a?(ClassInstance) ? fn.name : TypeChecker.get_mapped(fn.class), expr.token)
    end
    unless fn.arity.includes?(expr.arguments.size)
      arg_size = fn.arity.begin == fn.arity.end ? fn.arity.begin : fn.arity.to_s
      Logger.report_error("Expected #{arg_size} arguments, got", expr.arguments.size.to_s, expr.token)
    end

    arg_values = expr.arguments.map { |arg| evaluate(arg) }
    fn.call(arg_values)
  end

  def visit_var_expr(expr : Expression::Var) : ValueType
    @scope.lookup(expr.token)
  end

  def visit_var_declaration_expr(expr : Expression::VarDeclaration) : ValueType
    in_global = @meta["this"]?.nil?
    value = evaluate(expr.value)
    if in_global
      @scope.declare(
        expr.typedef,
        expr.var.token,
        value,
        const: expr.constant?,
        visibility: expr.visibility
      )
    else
      instance = @meta["this"].as ClassInstance
      instance.define_field(
        expr.var.token.lexeme,
        value,
        expr.token,
        visibility: expr.visibility,
        constant: expr.constant?,
        typedef: expr.typedef
      )
    end
  end

  def visit_multiple_declaration_expr(expr : Expression::MultipleDeclaration) : Array(ValueType)
    resultant_values = [] of ValueType

    expr.declarations.each do |declaration|
      resultant_values << evaluate(declaration)
    end

    resultant_values
  end

  def visit_var_assignment_expr(expr : Expression::VarAssignment) : ValueType
    value = expr.value.is_a?(Expression::Base) ? evaluate(expr.value.as Expression::Base) : expr.value
    @scope.assign(expr.var.token, TypeChecker.as_value_type(value))
  end

  def visit_multiple_assignment_expr(expr : Expression::MultipleAssignment) : Array(ValueType)
    values = [] of ValueType
    expr.assignments.each do |assignment|
      if assignment.is_a?(Expression::VarAssignment)
        if assignment.value.is_a?(Expression::Base)
          values << evaluate(assignment.value.as Expression::Base)
        else
          values << assignment.value.as ValueType
        end
      elsif assignment.is_a?(Expression::PropertyAssignment)
        if assignment.value.is_a?(Expression::Base)
          values << evaluate(assignment.value.as Expression::Base)
        else
          values << assignment.value.as ValueType
        end
      end
    end

    resolved_assignments = expr.assignments.map_with_index do |assignment, i|
      if assignment.is_a?(Expression::VarAssignment)
        assignment.value = values[i]
      elsif assignment.is_a?(Expression::PropertyAssignment)
        assignment.value = values[i]
      end
      assignment
    end

    resultant_values : Array(ValueType) = resolved_assignments.map do |assignment|
      evaluate(assignment)
    end

    resultant_values
  end

  def add_object_value(token : Token, object : V, key : ValueType, value : ValueType) : V forall V
    if object.is_a?(Array)
      unless key.is_a?(Int)
        Logger.report_error("Invalid index type", TypeChecker.get_mapped(key.class), token)
      end
      if object[key]?.nil?
        object.insert(key, value)
      else
        object[key] = value
      end
    elsif object.is_a?(Hash)
      object[key] = value
    elsif object.is_a?(ClassInstance)
      unless key.is_a?(String)
        Logger.report_error("Invalid index type", TypeChecker.get_mapped(key.class), token)
      end
      object.define_field(key, value, token)
    else
      Logger.report_error("Attempt to assign to index of", TypeChecker.get_mapped(object.class), token)
    end
    object
  end

  def visit_property_assignment_expr(expr : Expression::PropertyAssignment) : ValueType
    if expr.object.is_a?(Expression::Index)
      index = expr.object.as Expression::Index
      object_node = index.object
      key = evaluate(index.key)
      object = evaluate(object_node)
    else
      access = expr.object.as Expression::Access
      object_node = access.object
      key = access.key.lexeme
      object = evaluate(object_node)
    end

    value = expr.value.is_a?(Expression::Base) ?
      evaluate(expr.value.as Expression::Base)
      : expr.value.as ValueType

    if object_node.is_a?(Expression::Index) || object_node.is_a?(Expression::Access)
      object = add_object_value(expr.token, object, key, value)
      prop_assignment = Expression::PropertyAssignment.new(object_node, object)
      return visit_property_assignment_expr(prop_assignment)
    end

    object = add_object_value(expr.token, object, key, value)
    unless meta["this"]?.nil? || expr.token.lexeme != "$" || !object.is_a?(ClassInstance)
      value
    else
      @scope.assign(expr.token, object)
    end
  end

  def visit_compound_assignment_expr(expr : Expression::CompoundAssignment) : ValueType
    case expr.operator.type
    when Syntax::PlusEqual
      op = Operator::PlusAssign.new(self)
      op.apply(expr)
    when Syntax::MinusEqual
      op = Operator::MinusAssign.new(self)
      op.apply(expr)
    when Syntax::StarEqual
      op = Operator::MulAssign.new(self)
      op.apply(expr)
    when Syntax::SlashEqual
      op = Operator::DivAssign.new(self)
      op.apply(expr)
    when Syntax::PercentEqual
      op = Operator::ModAssign.new(self)
      op.apply(expr)
    when Syntax::CaratEqual
      op = Operator::PowAssign.new(self)
      op.apply(expr)
    when Syntax::AmpersandColonEqual
      op = Operator::AndAssign.new(self)
      op.apply(expr)
    when Syntax::PipeColonEqual
      op = Operator::OrAssign.new(self)
      op.apply(expr)
    end
  end

  def visit_ternary_op_expr(expr : Expression::TernaryOp) : ValueType
    condition = evaluate(expr.condition)

    return evaluate(expr.then) if condition
    evaluate(expr.else)
  end

  def visit_unary_op_expr(expr : Expression::UnaryOp) : ValueType
    operand = evaluate(expr.operand)
    case expr.operator.type
    when Syntax::Plus
      if operand.is_a?(ClassInstance)
        return Operator.call_meta_method(operand, nil, "unp$", expr.operator.lexeme, expr.operator)
      end
      if operand.is_a?(Float) || operand.is_a?(Int)
        operand.abs
      else
        Logger.report_error("Invalid '+' operand type", operand.class.to_s, expr.operator)
      end
    when Syntax::Minus
      if operand.is_a?(ClassInstance)
        return Operator.call_meta_method(operand, nil, "unm$", expr.operator.lexeme, expr.operator)
      end
      if operand.is_a?(Float) || operand.is_a?(Int)
        -operand
      else
        Logger.report_error("Invalid '-' operand type", operand.class.to_s, expr.operator)
      end
    when Syntax::PlusPlus
      op = Operator::PlusAssign.new(self)
      op.apply(expr, "++")
    when Syntax::MinusMinus
      op = Operator::MinusAssign.new(self)
      op.apply(expr, "--")
    when Syntax::Bang
      !operand
    when Syntax::Tilde
      op = Operator::Bnot.new(self)
      op.apply(expr)
    when Syntax::Star
      if operand.is_a?(ClassInstance)
        return Operator.call_meta_method(operand, nil, "splat$", expr.operator.lexeme, expr.operator)
      end
      raise "'*' unary operator has not yet implemented."
    when Syntax::Hashtag
      if operand.is_a?(ClassInstance)
        return Operator.call_meta_method(operand, nil, "size$", expr.operator.lexeme, expr.operator)
      end
      unless operand.is_a?(Array) || operand.is_a?(Hash) || operand.is_a?(String) || operand.is_a?(Range)
        Logger.report_error("Invalid '#' operand type", TypeChecker.get_mapped(operand.class), expr.operator)
      end
      operand.size
    end
  end

  def visit_binary_op_expr(expr : Expression::BinaryOp) : ValueType
    left = evaluate(expr.left)
    right = evaluate(expr.right)

    case expr.operator.type
    when Syntax::Plus
      op = Operator::Plus.new(self)
      op.apply(expr)
    when Syntax::Minus
      op = Operator::Minus.new(self)
      op.apply(expr)
    when Syntax::Star
      op = Operator::Mul.new(self)
      op.apply(expr)
    when Syntax::Slash
      op = Operator::Div.new(self)
      op.apply(expr)
    when Syntax::SlashSlash
      op = Operator::IntDiv.new(self)
      op.apply(expr)
    when Syntax::Carat
      op = Operator::Pow.new(self)
      op.apply(expr)
    when Syntax::Percent
      op = Operator::Mod.new(self)
      op.apply(expr)
    when Syntax::AmpersandColon
      left && right
    when Syntax::PipeColon
      left || right
    when Syntax::EqualEqual
      left == right
    when Syntax::BangEqual
      left != right
    when Syntax::Less
      op = Operator::LT.new(self)
      op.apply(expr)
    when Syntax::LessEqual
      op = Operator::LTE.new(self)
      op.apply(expr)
    when Syntax::Greater
      op = Operator::GT.new(self)
      op.apply(expr)
    when Syntax::GreaterEqual
      op = Operator::GTE.new(self)
      op.apply(expr)
    when Syntax::Tilde
      op = Operator::Bxor.new(self)
      op.apply(expr)
    when Syntax::Pipe
      op = Operator::Bor.new(self)
      op.apply(expr)
    when Syntax::Ampersand
      op = Operator::Band.new(self)
      op.apply(expr)
    when Syntax::RDoubleArrow
      op = Operator::Bshr.new(self)
      op.apply(expr)
    when Syntax::LDoubleArrow
      op = Operator::Bshl.new(self)
      op.apply(expr)
    end
  end

  def visit_range_literal_expr(expr : Expression::RangeLiteral) : Range(Int128 | Int64 | Int32 | Int16 | Int8, Int128 | Int64 | Int32 | Int16 | Int8)
    from = evaluate(expr.from)
    to = evaluate(expr.to)

    unless from.is_a?(Int)
      Logger.report_error("Invalid left side of range literal", "Ranges can only be of integers, got '#{TypeChecker.get_mapped(from.class)}'", expr.token)
    end
    unless to.is_a?(Int)
      Logger.report_error("Invalid right side of range literal", "Ranges can only be of integers, got '#{TypeChecker.get_mapped(to.class)}'", expr.token)
    end

    from .. to
  end

  def visit_table_literal_expr(expr : Expression::TableLiteral) : Hash(ValueType, ValueType)
    hash = {} of  ValueType => ValueType
    expr.hashmap.each do |k, v|
      key = evaluate(k)
      value = evaluate(v)
      hash[key] = value
    end
    hash
  end

  def visit_vector_literal_expr(expr : Expression::VectorLiteral) : Array(ValueType)
    expr.values.map { |v| evaluate(v) }
  end

  def visit_string_interpolation_expr(expr : Expression::StringInterpolation) : ValueType
    string_parts = expr.parts.map do |part|
      part.is_a?(String) ? part : evaluate(part).to_s
    end
    string_parts.join("")
  end

  def visit_literal_expr(expr : Expression::Literal) : ValueType
    expr.value
  end

  def visit_single_expr_stmt(stmt : Statement::SingleExpression) : ValueType
    evaluate(stmt.expression)
  end

  def visit_block_stmt(stmt : Statement::Block) : ValueType
    execute_block(stmt, Scope.new(@scope))
  end
end
