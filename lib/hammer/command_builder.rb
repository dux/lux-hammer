class Hammer
  # Context object for `define :name do ... end` blocks. Exposes
  # desc/example/opt/alt; the block's return value (a `proc do |opts|`)
  # becomes the command handler.
  class CommandBuilder
    def initialize(cmd)
      @cmd = cmd
    end

    def desc(text)
      @cmd.instance_variable_set(:@desc, text.to_s.rstrip)
    end

    def example(text)
      @cmd.add_example(text)
    end

    def opt(name, **opts)
      @cmd.add_option(Option.new(name, **opts))
    end

    def alt(*names)
      names.each { |n| @cmd.add_alt(n) }
    end
  end
end
