class Hammer
  # A single registered command on a Hammer class.
  class Command
    attr_reader :name, :desc, :options, :examples, :alts, :needs
    attr_accessor :handler

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
  end
end
