class Hammer
  # Context object for the block DSL - what runs inside a `Hammerfile`,
  # a `Hammer.run do ... end` block, or any other top-level fragment.
  # All methods proxy to the target Hammer subclass.
  class Builder
    def initialize(klass)
      @klass = klass
    end

    def task(name, &block)
      @klass.task(name, &block)
    end

    def namespace(name, &block)
      @klass.namespace(name, &block)
    end

    # Per-target / per-namespace pre-hook. Same semantics as
    # `Hammer.before` at the class level - see lux-hammer.rb.
    def before(&block)
      @klass.before(&block)
    end

    # Opt out of auto `.env` loading in `Hammer.cli`. Default is on.
    def dotenv(flag = true)
      @klass.dotenv(flag)
    end

    # Same surface as `Hammer.load`. Resolved relative to the file that
    # called us, so `load auto: true` inside a Hammerfile picks up
    # *_hammer.rb under the Hammerfile's directory.
    def load(*paths, **kwargs)
      anchor = Loader.caller_anchor(caller_locations(1, 1).first)
      @klass.loader.load(anchor, paths, kwargs)
    end

    # instance_eval wrapper that also publishes the current Hammer target
    # via Thread.current[:hammer_target]. That lets `*_hammer.rb` files
    # pulled in through Ruby's own `require` (e.g. `Dir.require_all
    # 'lib/tasks'` inside a Hammerfile) call `task`/`namespace`/`before`
    # at top-level scope and have them register on the right target.
    def evaluate(source = nil, path = nil, &block)
      Hammer.with_target(@klass) do
        block ? instance_eval(&block) : instance_eval(source, path)
      end
    end
  end

  # Top-level Hammer DSL. Extended onto `main` (below) so any file
  # `require`d from within a Hammerfile - where `self == main` - can
  # still call `task`, `namespace`, and `before`. Delegates to whichever
  # Hammer subclass is currently being evaluated.
  module DSL
    %i[task namespace before dotenv].each do |m|
      define_method(m) do |*args, &block|
        target = Thread.current[:hammer_target]
        raise Hammer::Error, "`#{m}` called outside a Hammer context " \
                             '(Hammerfile / Hammer.run block / *_hammer.rb)' unless target
        target.send(m, *args, &block)
      end
    end
  end
end

TOPLEVEL_BINDING.eval('self').extend(Hammer::DSL)
