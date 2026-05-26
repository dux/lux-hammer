class Hammer
  # A single registered command on a Hammer class.
  class Command
    attr_reader :name, :desc, :options, :examples, :alts, :needs
    attr_accessor :handler, :location, :prev_location

    def initialize(name:, desc: '', handler: nil)
      @name     = name.to_s
      @desc     = desc.to_s.rstrip
      @handler  = handler
      @options  = []
      @examples = []
      @alts     = []
      @needs    = []
    end

    # First line of `desc`, used in the flat command listing.
    def brief
      @desc.lines.first&.chomp.to_s
    end

    def add_option(option)
      @options << option
    end

    def add_example(text)
      @examples << text.to_s
    end

    def add_alt(name)
      @alts << name.to_s
    end

    def add_need(name)
      @needs << name.to_s
    end

    def matches?(name)
      name = name.to_s
      name == @name || @alts.include?(name)
    end

    # Auto-assign a single-letter short alias (first letter of the opt
    # name) to any opt that does not already declare one. Explicit
    # aliases and `-h` are reserved first, so they always win. On
    # collision the opt simply gets no short form - long flag still
    # works. Idempotent.
    def finalize!
      return if @finalized
      @finalized = true

      claimed = ['-h']
      @options.each do |o|
        o.aliases.each { |a| claimed << a if short_flag?(a) }
      end

      @options.each do |o|
        next if o.aliases.any? { |a| short_flag?(a) }
        short = "-#{o.name.to_s[0]}"
        next if claimed.include?(short)
        o.aliases << short
        claimed << short
      end
    end

    private

    def short_flag?(switch)
      switch.length == 2 && switch.start_with?('-') && switch[1] != '-'
    end
  end
end
