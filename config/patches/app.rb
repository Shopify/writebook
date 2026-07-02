# frozen_string_literal: true

# Application-level constants that the request path reads and that must be
# Ractor-shareable (frozen) to be read from a non-main Ractor.
require "active_support/ractors"

ActiveSupport::Ractors.on_freeze do
  if defined?(TranslationsHelper::TRANSLATIONS)
    Ractor.make_shareable(TranslationsHelper::TRANSLATIONS)
  end

  # Page#searchable_content renders Markdown (Redcarpet) and parses the result
  # into plain text (ActionText -> Nokogiri). Both are C extensions whose methods
  # are Ractor-unsafe (Ractor::UnsafeError off the main Ractor); Page also
  # memoizes its renderer in a class variable. Run the whole thing on the main
  # Ractor and bring back the (frozen) string.
  if defined?(Page)
    Page.prepend(Module.new do
      def searchable_content
        return super if Ractor.main?

        page_id = id
        Ractor::Dispatch.main.run do
          content = Page.find(page_id).searchable_content
          html_safe = content.respond_to?(:html_safe?) && content.html_safe?
          str = +content.to_s
          str = str.html_safe if html_safe
          Ractor.make_shareable(str)
        end
      end

      # Markdown display rendering (html_preview and friends) also goes through
      # Redcarpet; run it on the main Ractor and bring back the html_safe HTML.
      def rendered_html(source)
        return super if Ractor.main?

        src = -source.to_s
        Ractor::Dispatch.main.run { -Page.preview_renderer.render(src).to_s }
      end
    end)
  end

  # HTML sanitization uses Loofah -> Nokogiri (Ractor-unsafe), so sanitize the
  # page content on the main Ractor and bring back the html_safe result.
  if defined?(PagesHelper)
    PagesHelper.prepend(Module.new do
      def sanitize_content(content)
        return super if Ractor.main?

        html = -content.to_s
        result = Ractor::Dispatch.main.run do
          sanitized = ApplicationController.helpers.sanitize(html, scrubber: HtmlScrubber.new)
          Ractor.make_shareable(-sanitized.to_s)
        end
        result.html_safe
      end
    end)
  end

  # The full-text search index callbacks render Markdown (see above) and reach
  # for the raw SQLite connection (raw_connection.changes) -- both main-only.
  # Dispatch the whole index update to the main Ractor, by leaf id.
  if defined?(Leaf)
    Leaf.prepend(Module.new do
      def create_in_search_index
        Ractor.main? ? super : dispatch_search_index_to_main(:create_in_search_index)
      end

      def update_in_search_index
        Ractor.main? ? super : dispatch_search_index_to_main(:update_in_search_index)
      end

      def remove_from_search_index
        Ractor.main? ? super : dispatch_search_index_to_main(:remove_from_search_index)
      end

      private
        def dispatch_search_index_to_main(meth)
          leaf_id = id
          Ractor::Dispatch.main.run do
            Leaf.find(leaf_id).send(meth)
            nil
          end
        end
    end)
  end
end
