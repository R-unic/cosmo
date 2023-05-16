require "../syntax_type"

module Cosmo::Keywords
  KEYWORDS = {
    "true" => Syntax::Boolean,
    "false" => Syntax::Boolean,
    "none" => Syntax::None,
    "fn" => Syntax::Function,
    "if" => Syntax::If,
    "unless" => Syntax::Unless,
    "in" => Syntax::In,
    "of" => Syntax::Of,
    "is" => Syntax::Is,
    "else" => Syntax::Else,
    "every" => Syntax::Every,
    "while" => Syntax::While,
    "until" => Syntax::Until,
    "break" => Syntax::Break,
    "next" => Syntax::Next,
    "match" => Syntax::Match,
    "const" => Syntax::Constant,
    "return" => Syntax::Return
  }

  # These cannot be any of the keywords above
  TYPE_KEYWORDS = ["type", "any", "bool", "string", "char", "int", "float", "void"]

  # Returns whether or not `s` is a type keyword
  def self.type?(s : String)
    TYPE_KEYWORDS.includes?(s)
  end

  # Returns whether or not `s` is a regular keyword
  def self.keyword?(s : String)
    KEYWORDS.has_key?(s)
  end

  # Returns the syntax type of `s` if it is a regular keyword
  def self.get_syntax(s : String) : Syntax
    KEYWORDS.fetch(s) { raise "Invalid keyword #{s}" }
  end
end
