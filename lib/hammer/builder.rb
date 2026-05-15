class Hammer
  # Context object for the block DSL - what runs inside a `Hammerfile`,
  # a `Hammer.run do ... end` block, or any other top-level fragment.
  # All methods proxy to the target Hammer subclass.
  class Builder
    def initialize(klass)
      @klass = klass
    end

    def program(name)
      @klass.program_name(name)
    end

    def define(name, &block)
      @klass.define(name, &block)
    end

    def namespace(name, &block)
      @klass.namespace(name, &block)
    end

    # Per-target / per-namespace pre-hook. Same semantics as
    # `Hammer.before` at the class level - see lux-hammer.rb.
    def before(&block)
      @klass.before(&block)
    end

    # Same surface as `Hammer.load`. Resolved relative to the file that
    # called us, so `load auto: true` inside a Hammerfile picks up
    # *_hammer.rb under the Hammerfile's directory.
    def load(*paths, **kwargs)
      anchor = Loader.caller_anchor(caller_locations(1, 1).first)
      @klass.loader.load(anchor, paths, kwargs)
    end
  end
end
