require "./lexer/token"
require "./lexer/keywords"

alias Cosmo::LiteralType =
  Int128 | Int64 | Int32 | Int16 | Int8 |
  UInt64 | UInt32 | UInt16 | UInt8 |
  Float64 | Float32 |
  Bool | String | Char | Nil

class Cosmo::Lexer
  @tokens : Array(Token)
  @line : UInt32 = 1
  @position : UInt32 = 0
  @char_pos : UInt32 = 0
  @tokens = [] of Token
  @current_lexeme = String::Builder.new

  def initialize(@source : String, @file_path : String, @run_benchmarks : Bool)
  end

  # Entry point: returns an array of tokens representing the source code
  def tokenize : Array(Token)
    start_time = Time.monotonic

    until finished?
      lex
    end

    add_token(Syntax::EOF, nil)
    end_time = Time.monotonic
    puts "Lexer @#{@file_path} took #{Util.get_elapsed(start_time, end_time)}." if @run_benchmarks

    @tokens
  end

  # Called for every character in the source code
  private def lex : Nil
    char = current_char
    @current_lexeme.write(char.to_slice)
    return add_newline if char == "\n"
    return skip_whitespace if char.blank?

    case char
    when "."
      if char_exists?(1) && !!(/[0-9]/ =~ peek)
        read_number
      else
        if match_char?(".")
          add_token(Syntax::DotDot, nil)
        else
          add_token(Syntax::Dot, nil)
        end
      end
    when "{"
      if match_char?("{")
        add_token(Syntax::DoubleLBrace, nil)
      else
        add_token(Syntax::LBrace, nil)
      end
    when "}"
      if match_char?("}")
        add_token(Syntax::DoubleRBrace, nil)
      else
        add_token(Syntax::RBrace, nil)
      end
    when "["
      add_token(Syntax::LBracket, nil)
    when "]"
      add_token(Syntax::RBracket, nil)
    when "("
      add_token(Syntax::LParen, nil)
    when ")"
      add_token(Syntax::RParen, nil)
    when "$"
      add_token(Syntax::This, nil)
    when ","
      add_token(Syntax::Comma, nil)
    when ";"
      add_token(Syntax::Semicolon, nil)
    when "\"", "'"
      read_string(char)
    when "~"
      add_token(Syntax::Tilde, nil)
    when "#"
      if match_char?("#")
        skip_comments(multiline: false)
      elsif match_char?(":")
        skip_comments(multiline: true)
      else
        add_token(Syntax::Hashtag, nil)
      end
    when ":"
      if match_char?(":")
        add_token(Syntax::ColonColon, nil)
      else
        add_token(Syntax::Colon, nil)
      end
    when "+"
      if match_char?("=")
        add_token(Syntax::PlusEqual, nil)
      elsif match_char?("+")
        add_token(Syntax::PlusPlus, nil)
      else
        add_token(Syntax::Plus, nil)
      end
    when "-"
      if match_char?("=")
        add_token(Syntax::MinusEqual, nil)
      elsif match_char?("-")
        add_token(Syntax::MinusMinus, nil)
      elsif match_char?(">")
        add_token(Syntax::HyphenArrow, nil)
      else
        add_token(Syntax::Minus, nil)
      end
    when "*"
      if match_char?("=")
        add_token(Syntax::StarEqual, nil)
      else
        add_token(Syntax::Star, nil)
      end
    when "/"
      if match_char?("=")
        add_token(Syntax::SlashEqual, nil)
      elsif match_char?("/")
        if match_char?("=")
          add_token(Syntax::SlashSlashEqual, nil)
        else
          add_token(Syntax::SlashSlash, nil)
        end
      else
        add_token(Syntax::Slash, nil)
      end
    when "^"
      if match_char?("=")
        add_token(Syntax::CaratEqual, nil)
      else
        add_token(Syntax::Carat, nil)
      end
    when "%"
      if match_char?("=")
        add_token(Syntax::PercentEqual, nil)
      elsif match_char?("[")
        read_string("]", multiline: true)
      elsif match_char?("(")
        read_string(")", multiline: true)
      else
        add_token(Syntax::Percent, nil)
      end
    when "&"
      add_token(Syntax::Ampersand, nil)
    when "|"
      add_token(Syntax::Pipe, nil)
    when "?"
      if match_char?(":")
        if match_char?("=")
          add_token(Syntax::QuestionColonEqual, nil)
        else
          add_token(Syntax::QuestionColon, nil)
        end
      else
        add_token(Syntax::Question, nil)
      end
    when "!"
      if match_char?("=")
        add_token(Syntax::BangEqual, nil)
      else
        report_error("Unexpected character", "!")
      end
    when "="
      if match_char?("=")
        add_token(Syntax::EqualEqual, nil)
      elsif match_char?(">")
        add_token(Syntax::FatArrow, nil)
      else
        add_token(Syntax::Equal, nil)
      end
    when "<"
      if match_char?("=")
        add_token(Syntax::LessEqual, nil)
      elsif match_char?("<")
        add_token(Syntax::LDoubleArrow, nil)
      else
        add_token(Syntax::Less, nil)
      end
    when ">"
      if match_char?("=")
        add_token(Syntax::GreaterEqual, nil)
      elsif match_char?(">")
        add_token(Syntax::RDoubleArrow, nil)
      else
        add_token(Syntax::Greater, nil)
      end
    else
      default_char = current_char
      return skip_whitespace if default_char.blank?

      is_ident = !!(/([a-zA-Z_$]|\p{L})/ =~ default_char)
      is_number = !!(/\d/ =~ default_char) ||
        (default_char == "0" && peek == "x" && peek(2).match(/[0-9a-fA-F]/)) ||
        (default_char == "0" && peek == "b" && peek(2).match(/[01]/))

      if is_number
        read_number
      elsif is_ident
        read_identifier
      else
        report_error("Unexpected character", default_char)
      end
    end

    @position += 1
  end

  # Peek `offset` characters ahead of our current position
  # Returns a string because it's easier
  private def peek(offset : UInt32 = 1) : String
    @source[@position + offset].to_s
  end

  private def current_char : String
    peek 0
  end

  # Advances and returns true if the current character is `expected`
  # Returns false otherwise
  private def match_char?(expected)
    return false if finished?
    return false unless char_exists?(1)
    return false unless peek == expected

    if expected == "\n"
      add_newline
    else
      advance
      @current_lexeme.write(current_char.to_slice)
    end

    true
  end

  private def finished?
    @position >= @source.size
  end

  private def char_exists?(offset)
    (@position + offset) < @source.size
  end

  # Advances, adds a newline, and resets the current row
  private def add_newline
    advance
    @line += 1
    @char_pos = 0
  end

  # Adds to the current position, and returns the current character before adding to the position
  private def advance : String
    char = current_char
    @position += 1
    @char_pos += 1
    char
  end

  # Pushes a token with the given syntax and value to `@tokens`
  private def add_token(syntax : Syntax, value : LiteralType) : Nil
    location = Token::Location.new(@file_path, @line, @char_pos + 1)
    @tokens << Token.new(@current_lexeme.to_s, syntax, value, location)
    @current_lexeme = String::Builder.new
  end

  # Returns whether or not `char` and it's following characters are a number literal (e.x. `0xfff` or `0b1101`)
  private def matches_base?(char : String, radix : Int) : Bool
    current_char == "0" &&
      char_exists?(1) &&
      peek == char &&
      char_exists?(2) &&
      !peek(2).to_i(radix).nil?
  end

  # Advances all characters that are part of a comment
  private def skip_comments(multiline : Bool)
    @current_lexeme = String::Builder.new
    advance
    until end_of_comment?(multiline, @line)
      advance
    end
  end

  # Whether or not the comment is finished being consumed
  private def end_of_comment?(multiline : Bool, current_line : UInt32) : Bool
    multiline ?
      match_char?(":") && match_char?("#")
      : match_char?("\n") || finished?
  end

  # Advances all characters that are blank
  private def skip_whitespace : Nil
    @current_lexeme = String::Builder.new
    until finished? || !current_char.blank?
      advance
    end
  end

  # Advances all number characters and adds a integer/float token
  private def read_number : Nil
    num_str = ""
    radix = 10
    if is_base?("x", 16)
      advance
      advance
      radix = 16
    elsif is_base?("b", 2)
      advance
      advance
      radix = 2
    elsif is_base?("o", 8)
      advance
      advance
      radix = 8
    end

    decimal_used = false
    until finished?
      char = current_char.downcase
      is_valid = char.to_i64?(radix).nil? ? false : char.to_i64(radix).to_s(radix) == char
      break unless is_valid || (char == "." && !!(peek =~ /\d/))
      decimal_used = true if char == "." && !!(peek =~ /\d/)
      num_str += advance.to_s
    end

    @current_lexeme = String::Builder.new(num_str)
    if decimal_used
      report_error("Unexpected float", "Hex/octal/binary literals must be integers") unless radix == 10
      add_token(Syntax::FloatLiteral, num_str.to_f64)
    else
      add_token(Syntax::IntegerLiteral, num_str.to_i128(radix))
    end

    @position -= 1
  end

  # Advances all character/string characters and adds a character/string token
  private def read_string(delim : String, multiline = false) : Nil
    advance
    res_str = ""
    escaping = false

    until finished?
      if escaping
        case current_char
        when "n" # newline
          res_str += "\n"
        when "t" # tab
          res_str += "\t"
        when "e" # tab
          unless match_char?("[")
            report_error("Invalid escape sequence", "\\e escape sequence contained no '[' character")
          end

          contents = ""
          until match_char?("m")
            advance
            contents += current_char
          end
          res_str += "\e[#{contents}m"
        when "\\" # backslash
          res_str += "\\"
        when "\"" # double quote
          res_str += "\""
        when "'" # single quote
          res_str += "'"
        else
          res_str += current_char
        end

        advance
        escaping = false
      elsif current_char == "\\"
        advance
        escaping = true
      elsif current_char == delim
        if res_str.size == 0 && delim == "'"
          report_error("Character underflow", "Character literal must have exactly one character")
        end
        break
      elsif delim == "'"
        res_str += advance
        if res_str.size > 1
          report_error("Character overflow", "Character literal must have exactly one character")
        end
      else
        if current_char == "\n"
          add_newline
        else
          res_str += advance
        end
      end

      if current_char == "\n" && !multiline
        report_error("Invalid string literal", "Newline found in single-line string")
      end
    end

    @current_lexeme = String::Builder.new(res_str)
    add_token(
      delim == "'" ? Syntax::CharLiteral : Syntax::StringLiteral,
      delim == "'" ? res_str.chars.first
        : multiline ? res_str.strip : res_str
    )
  end

  # Advances all identifier characters and adds an identifier or keyword token
  private def read_identifier : Nil
    ident_str = ""
    until finished?
      # as soon as it's not a valid identifier character,
      # add the current character and end the loop
      if char_exists?(1) && !(/([a-zA-Z0-9_$?!]|\p{L})/ =~ peek)
        ident_str += current_char
        skip_whitespace
        break
      end
      if ident_str.ends_with?("?")
        report_error("Invalid identifier '#{ident_str + advance}'", "An identifier can only contain one '?' character, and only as the last character")
      elsif ident_str.ends_with?("!")
        report_error("Invalid identifier '#{ident_str + advance}'", "An identifier can only contain one '!' character, and only as the last character")
      end
      ident_str += advance
    end

    ident_str = ident_str.strip
    @current_lexeme = String::Builder.new(ident_str)
    if Keywords.keyword?(ident_str)
      syntax_type = Keywords.get_syntax(ident_str)

      value = nil
      value = true if ident_str == "true"
      value = false if ident_str == "false"
      if (ident_str == "and" || ident_str == "or") && match_char?("=")
        syntax_type = ident_str == "and" ? Syntax::AndEqual : Syntax::OrEqual
        add_token(syntax_type, nil)
      else
        add_token(syntax_type, value)
      end
    elsif Keywords.type?(ident_str)
      syntax_type = Keywords.get_type_syntax(ident_str)
      add_token(syntax_type, ident_str)
    elsif Keywords.class_visibility?(ident_str)
      add_token(Syntax::ClassVisibility, ident_str)
    elsif ident_str == "public"
      add_token(Syntax::Public, ident_str)
    else
      split = ident_str.split("?")
      if !split.empty? && Keywords.type?(split.first)
        syntax_type = Keywords.get_type_syntax(ident_str)
        add_token(syntax_type, ident_str)
      else
        add_token(Syntax::Identifier, ident_str)
      end
    end
  end

  # Shortcut to `Logger.report_error`
  private def report_error(type : String, message : String) : Nil
    Logger.report_error(type, message, @line, @char_pos, @file_path)
  end
end
