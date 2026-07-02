# ruby-vips / glib / gobject expose module constants that hold FFI::Function,
# Proc and Hash objects created at load time. ActiveStorage analyzes uploaded
# images (e.g. the book cover on /first_run) with libvips, so a non-main Ractor
# touches these constants. They're effectively immutable, so deep-freeze them
# for Ractor sharing.
ActiveSupport::Ractors.on_freeze do
  begin
    require "vips"
  rescue LoadError
    next
  end

  [defined?(GLib) && GLib, defined?(GObject) && GObject, defined?(Vips) && Vips].each do |mod|
    next unless mod

    mod.constants.each do |const_name|
      value = mod.const_get(const_name) rescue next
      next if Ractor.shareable?(value)

      Ractor.make_shareable(value) rescue nil
    end
  end

  # GLib.logger holds a stdlib Logger (unshareable: it wraps a Mutex). vips calls
  # GLib.logger.debug { ... } deep in its operation dispatch, so a non-main
  # Ractor needs a shareable logger. Swap in a frozen no-op logger.
  if defined?(GLib) && GLib.respond_to?(:logger)
    null_logger = Class.new do
      def debug(*); end
      def info(*); end
      def warn(*); end
      def error(*); end
      def fatal(*); end
      def level; 5; end
      def level=(_); end
      def add(*); end
      def <<(_); end
    end.new
    Ractor.make_shareable(null_logger)
    GLib.instance_variable_set(:@logger, null_logger)
  end
end
