class Hammer
  # Discovers and evaluates Hammerfile fragments (`*_hammer.rb`) against
  # a target `Hammer` subclass. One Loader per target class - the
  # target memoises it via `target.loader`. Holds the per-target dedup
  # cache so re-entrant `load` is safe.
  class Loader
    SKIP_DIRS ||= %w[.git .bundle node_modules tmp vendor dist build coverage].freeze

    attr_reader :loaded

    def initialize(target)
      @target = target
      @loaded = {}
    end

    # Resolve `caller_locations(...).first` to a directory.
    def self.caller_anchor(loc)
      path = loc&.absolute_path || loc&.path
      path ? File.dirname(path) : Dir.pwd
    end

    def load(anchor, paths, kwargs)
      bad = kwargs.keys - %i[auto]
      raise Hammer::Error, "load: unknown option(s): #{bad.join(', ')}" unless bad.empty?
      return if kwargs.key?(:auto) && !kwargs[:auto]

      files =
        if paths.empty?
          discover(anchor)
        else
          paths.flat_map { |p| resolve_pattern(anchor, p) }.uniq.sort
        end

      files.each { |f| load_one(f) }
    end

    private

    def resolve_pattern(anchor, pattern)
      abs = File.expand_path(pattern, anchor)
      matches =
        if abs.match?(/[\*\?\[\{]/)
          Dir.glob(abs)
        elsif File.file?(abs)
          [abs]
        else
          []
        end
      raise Hammer::Error, "load: no files matched #{pattern.inspect}" if matches.empty?
      matches.sort
    end

    def discover(dir)
      return [] unless File.directory?(dir)
      out = []
      walk(dir, out)
      out.sort
    end

    def walk(dir, out)
      Dir.each_child(dir) do |entry|
        full = File.join(dir, entry)
        if File.directory?(full)
          next if SKIP_DIRS.include?(entry) || entry.start_with?('.')
          walk(full, out)
        elsif entry.end_with?('_hammer.rb')
          out << full
        end
      end
    end

    def load_one(abs_path)
      return if @loaded[abs_path]
      @loaded[abs_path] = true
      Builder.new(@target).instance_eval(File.read(abs_path), abs_path)
    rescue Hammer::Error
      raise
    rescue StandardError => e
      raise Hammer::Error, "failed loading #{abs_path}: #{e.message}"
    end
  end
end
