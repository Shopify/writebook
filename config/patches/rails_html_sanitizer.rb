# frozen_string_literal: true

# rails-html-sanitizer stores its allow-lists (allowed_tags / allowed_attributes)
# in class-level instance variables on the sanitizer classes. HTML sanitization
# runs on the view path (PagesHelper#sanitize_content -> HtmlScrubber), so a
# non-main Ractor reads them. They're effectively immutable allow-lists; freeze
# them for Ractor sharing.
require "active_support/ractors"

ActiveSupport::Ractors.on_freeze do
  sanitizer_classes = [
    ("Rails::HTML4::SafeListSanitizer" if defined?(Rails::HTML4::SafeListSanitizer)),
    ("Rails::HTML5::SafeListSanitizer" if defined?(Rails::HTML5::SafeListSanitizer)),
    ("Rails::Html::WhiteListSanitizer" if defined?(Rails::Html::WhiteListSanitizer)),
  ].compact.map { |name| name.constantize rescue nil }.compact.uniq

  sanitizer_classes.each do |klass|
    %i[@allowed_tags @allowed_attributes].each do |ivar|
      next unless klass.instance_variable_defined?(ivar)

      value = klass.instance_variable_get(ivar)
      next if value.nil? || Ractor.shareable?(value)

      klass.instance_variable_set(ivar, Ractor.make_shareable(value)) rescue nil
    end
  end
end
