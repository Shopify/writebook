# frozen_string_literal: true

# front_matter_parser (used by DemoContent to parse the demo markdown pages)
# builds its syntax-parser classes (FrontMatterParser::SyntaxParser::Md, Html,
# ...) at load time via `define_singleton_method(:delimiters) { delimiters }`.
# That method is defined with a non-shareable Proc, so it can't be called from a
# non-main Ractor. delimiters just returns a fixed array, so redefine it with a
# Ractor-shareable Proc returning a frozen copy.
require "active_support/ractors"

ActiveSupport::Ractors.on_freeze do
  next unless defined?(FrontMatterParser::SyntaxParser)

  FrontMatterParser::SyntaxParser.constants.each do |const|
    klass = FrontMatterParser::SyntaxParser.const_get(const)
    next unless klass.is_a?(Class)

    current =
      begin
        klass.delimiters
      rescue StandardError, NotImplementedError
        next # base classes (SingleLineComment, ...) raise NotImplementedError
      end
    delimiters = Ractor.make_shareable(current.dup)
    klass.define_singleton_method(:delimiters, &Ractor.shareable_proc { delimiters })
  end
end
