require_relative 'hammer/shell'
require_relative 'hammer/option'
require_relative 'hammer/parser'
require_relative 'hammer/command'
require_relative 'hammer/loader'
require_relative 'hammer/builder'
require_relative 'hammer/command_builder'

# Thor-inspired tiny CLI builder.
#
# Class DSL:
#
#   class MyCli < Hammer
#     task :build do
#       desc    'Build the project'
#       example 'build -v --env=prod'
#       opt :verbose, type: :boolean, alias: :v
#       opt :env,     type: :string,  default: 'dev'
#       proc do |opts|
#         say.green "building #{opts[:env]} args=#{opts[:args].inspect}"
#       end
#     end
#   end
#
#   MyCli.start(ARGV)
#
# Block DSL is identical, just inside `Hammer.run`:
#
#   Hammer.run(ARGV) do
#     task :hello do
#       desc 'Greet someone'
#       opt :loud, type: :boolean, alias: :l
#       proc do |opts|
#         msg = "hello #{opts[:args].first || 'world'}"
#         msg = msg.upcase if opts[:loud]
#         say msg, :cyan
#       end
#     end
#   end
class Hammer
  include Shell

  Error ||= Class.new(StandardError)

  class << self
    def inherited(sub)
      super
      sub.instance_variable_set(:@commands, {})
      sub.instance_variable_set(:@namespaces, {})
      sub.instance_variable_set(:@before_hooks, [])
      sub.instance_variable_set(:@parent, nil)
      sub.instance_variable_set(:@program_name, nil)
      sub.instance_variable_set(:@pending_desc, nil)
      sub.instance_variable_set(:@pending_examples, [])
      sub.instance_variable_set(:@pending_options, [])
      sub.instance_variable_set(:@pending_alts, [])
      sub.instance_variable_set(:@pending_needs, [])
    end

    # ----- class-level DSL for `def`-style commands ---------------------
    # Set pending metadata that the next `def` will consume.
    #
    #   class MyCli < Hammer
    #     desc 'Build'
    #     opt :env, default: 'dev'
    #     def build(opts)
    #       say "building #{opts[:env]}"
    #     end
    #   end

    def desc(text)       ; @pending_desc = text.to_s.rstrip end
    def example(text)    ; @pending_examples << text end
    def opt(name, **o)   ; @pending_options << Option.new(name, **o) end
    def alt(*names)      ; @pending_alts.concat(names) end
    def needs(*names)    ; @pending_needs.concat(names) end

    def method_added(method_name)
      super
      return unless @pending_desc

      cmd = Command.new(name: method_name.to_s, desc: @pending_desc)
      @pending_examples.each { |e| cmd.add_example(e) }
      @pending_options.each  { |o| cmd.add_option(o) }
      @pending_alts.each     { |n| cmd.add_alt(n) }
      @pending_needs.each    { |n| cmd.add_need(n) }

      # If the method takes no args, call it without opts. Otherwise pass
      # opts. So both `def build` and `def build(opts)` work.
      m = method_name
      arity = instance_method(method_name).arity
      cmd.handler = arity.zero? ? proc { send(m) } : proc { |opts| send(m, opts) }
      commands[cmd.name] = cmd

      @pending_desc = nil
      @pending_examples = []
      @pending_options  = []
      @pending_alts     = []
      @pending_needs    = []
    end

    # Resolved lazily on first read and memoized, so callers that need the
    # cwd-relative form (see `default_program_name`) can warm the cache
    # before chdir-ing elsewhere.
    def program_name
      @program_name ||= default_program_name
    end

    # Program name shown in help/usage: the invocation path relative to cwd
    # if the script lives inside it (e.g. `bin/foo` when invoked from the
    # project root), otherwise the basename (e.g. `lux` for a globally
    # installed bin in PATH).
    def default_program_name
      prog = $PROGRAM_NAME
      return File.basename(prog) unless prog.include?('/')
      # Resolve symlinks on both sides so e.g. macOS `/tmp` -> `/private/tmp`
      # doesn't cause a false miss when comparing prefixes.
      abs = File.realpath(prog) rescue File.expand_path(prog)
      cwd = File.realpath(Dir.pwd) rescue Dir.pwd
      return abs[(cwd.length + 1)..] if abs.start_with?("#{cwd}/")
      File.basename(prog)
    end

    # Define a command. Block runs in a CommandBuilder context and must
    # return a Proc as its last expression. That proc is the handler and
    # receives a single `opts` hash with symbol keys; positional ARGV
    # lives at `opts[:args]`.
    def task(name, &block)
      cmd = Command.new(name: name.to_s)
      handler = CommandBuilder.new(cmd).instance_eval(&block)
      unless handler.is_a?(Proc)
        raise Error, <<~MSG
          task(:#{name}) block must end with a `proc do |opts| ... end`.
          The proc's return value is what becomes the command handler.

          Example:

            task :#{name} do
              desc    'what it does'
              example '#{name} foo --env=prod'
              opt :env, default: 'dev'

              proc do |opts|
                # your code here - opts[:env], opts[:args], ...
              end
            end
        MSG
      end
      cmd.handler = handler
      commands[cmd.name] = cmd

      # `task` ignores pending class-level state, but clear it so a
      # later `def` doesn't accidentally consume stale metadata.
      @pending_desc = nil
      @pending_examples = []
      @pending_options  = []
      @pending_alts     = []
      @pending_needs    = []
    end

    # Open a namespace (group of commands). Everything inside the block
    # (task, nested namespace, ...) belongs to that namespace, evaluated
    # against an anonymous Hammer subclass.
    #
    #   namespace :db do
    #     task :migrate do ... end
    #     namespace :users do ... end
    #   end
    def namespace(name, &block)
      sub = Class.new(Hammer)
      # Track the top-level CLI class so cross-invocation
      # (`hammer 'ns:cmd'`) from inside a namespaced command dispatches
      # against the full tree, not just the current namespace.
      sub.instance_variable_set(:@root, root)
      # Parent link, so `before` hooks defined further up the namespace
      # tree can be collected and run outer -> inner before a command.
      sub.instance_variable_set(:@parent, self)
      # Share the parent's resolved program_name so help banners show
      # "myapp ns:cmd" with the same prefix everywhere - and so the value
      # captured pre-chdir (see `Hammer.cli`) survives into nested classes.
      sub.instance_variable_set(:@program_name, program_name)
      sub.class_eval(&block) if block
      @namespaces[name.to_s] = sub
    end

    # Register a hook to run before every command in this class (root or
    # namespace). Hooks receive the command's `opts` hash. All hooks run
    # outer -> inner, once per top-level `start` (prereqs don't re-trigger).
    #
    #   before { |opts| Dotenv.load }
    #   namespace :db do
    #     before { hammer :env }
    #     task :migrate do ... end
    #   end
    def before(&block)
      before_hooks << block
    end

    def before_hooks
      @before_hooks
    end

    def parent
      @parent
    end

    # Root -> ... -> self. Used to gather `before` hooks for a command.
    def ancestor_chain
      chain = []
      klass = self
      while klass
        chain.unshift klass
        klass = klass.parent
      end
      chain
    end

    # Topmost class in this CLI tree. For user-defined `class MyCli < Hammer`
    # or `Class.new(Hammer)` it's self; for namespace subclasses it's
    # whichever class opened the namespace.
    def root
      @root || self
    end

    def commands
      @commands ||= {}
    end

    def namespaces
      @namespaces ||= {}
    end

    # Per-target Loader instance. Owns the dedup cache, so re-entrant
    # `load` from inside a fragment is safe and idempotent.
    def loader
      @loader ||= Loader.new(self)
    end

    # Load Hammerfile fragments and register their commands on this
    # class. Rake-style: split a CLI across multiple files.
    #
    #   load                        # auto-discover *_hammer.rb under caller dir
    #   load auto: true             # same
    #   load 'tasks/db_hammer.rb'   # one file
    #   load 'tasks/*_hammer.rb'    # glob
    #
    # Paths resolve relative to the file calling `load`. See
    # `Hammer::Loader` for the full implementation.
    def load(*paths, **kwargs)
      if self == Hammer
        raise Error, 'use `load` from inside a Hammerfile / Hammer.run block / Hammer subclass body, ' \
                     'or call SubClass.load - Hammer.load itself has no target'
      end
      anchor = Loader.caller_anchor(caller_locations(1, 1).first)
      loader.load(anchor, paths, kwargs)
    end

    # Entry point. Parses ARGV, finds the right command, runs it.
    # Command names are Rake-style colon paths: "build", "db:migrate",
    # "db:users:list".
    #
    # Rake-style chained dispatch: `hammer build + deploy + notify`.
    # A bare `+` argv token separates commands; `++` escapes to a literal
    # `+` positional. Quoted shell args (`--foo="a + b"`) arrive as a
    # single token and are not split.
    def start(argv = ARGV)
      # Track prereqs fired during this top-level invocation so a `needs`
      # chain runs each prereq at most once. Nested `start` calls (e.g.
      # `needs` -> `hammer` -> `start`, or a `+` chain) share the set;
      # the outermost call owns its lifetime.
      outer = Thread.current[:hammer_needs_ran].nil?
      Thread.current[:hammer_needs_ran] ||= {}
      Thread.current[:hammer_before_ran] ||= {}

      split_chain(argv).each { |seg| dispatch(seg) }
    ensure
      Thread.current[:hammer_needs_ran] = nil if outer
      Thread.current[:hammer_before_ran] = nil if outer
    end

    private

    # Split argv on bare `+` tokens; unescape `++` -> `+` within each
    # segment. Returns [argv] when no chain operator is present.
    def split_chain(argv)
      return [argv] unless argv.include?('+') || argv.include?('++')
      segs = argv.slice_when { |a, b| a == '+' || b == '+' }
                 .map { |seg| seg.reject { |t| t == '+' } }
                 .map { |seg| seg.map { |t| t == '++' ? '+' : t } }
                 .reject(&:empty?)
      segs.empty? ? [argv] : segs
    end

    # Run a single (already-split) command segment.
    def dispatch(argv)
      argv = argv.dup
      name = argv.shift

      if name.nil? || name == 'help' || name == '-h' || name == '--help'
        target = argv.shift
        return print_help(target)
      end

      # Trailing colon ("db:") -> expanded namespace listing with full
      # per-command help on every task. Bare ":" expands the root.
      if name.end_with?(':') && name != ':'
        bare = name.chomp(':')
        ns = resolve_namespace(bare)
        return print_namespace_help(bare, ns, full: true) if ns
        Shell.print_error("unknown namespace: #{bare}")
        print_help
        exit 1
      elsif name == ':'
        return print_help(nil, full: true)
      end

      cmd, owner = resolve(name)
      return owner.run_command(cmd, argv, full: name) if cmd

      ns = resolve_namespace(name)
      return print_namespace_help(name, ns) if ns

      Shell.print_error("unknown command: #{name}")
      print_help
      exit 1
    end

    public

    # Find a command by canonical name or alt within this class.
    def find_command(name)
      commands[name.to_s] || commands.values.find { |c| c.matches?(name) }
    end

    # Walk "ns1:ns2:cmd" -> [command, owning_class]. Returns [nil, nil]
    # if any segment is missing or the final segment isn't a command.
    def resolve(path)
      parts = path.to_s.split(':')
      klass = self
      parts[0..-2].each do |ns|
        klass = klass.namespaces[ns] or return [nil, nil]
      end
      cmd = klass.find_command(parts.last)
      cmd ? [cmd, klass] : [nil, nil]
    end

    # Walk "ns1:ns2" -> namespace class, or nil if any segment missing.
    def resolve_namespace(path)
      parts = path.to_s.split(':')
      klass = self
      parts.each { |ns| klass = klass.namespaces[ns] or return nil }
      klass
    end

    # Programmatic dispatch by name. Useful for scripting and tests.
    #
    #   MyCli.hammer :build                       -> start(["build"])
    #   MyCli.hammer 'db:users:list'              -> start(["db:users:list"])
    #   MyCli.hammer :eval, 'puts 42'             -> start(["eval", "puts 42"])
    #   MyCli.hammer :build, env: 'prod'          -> start(["build", "--env=prod"])
    #   MyCli.hammer :build, verbose: true        -> start(["build", "--verbose"])
    #   MyCli.hammer :build, no_cache: true       -> start(["build", "--no-cache"])
    #   MyCli.hammer :build, cache: false         -> skipped (no-op)
    #
    # Symbols are single-segment names; pass a string with colons for
    # namespaced paths. Trailing positionals become positional ARGV.
    # Underscores in option keys become dashes in flags.
    def hammer(name, *args, **opts)
      argv = [name.to_s, *args.map(&:to_s)]
      opts.each do |k, v|
        next if v == false
        flag = "--#{k.to_s.tr('_', '-')}"
        argv << (v == true ? flag : "#{flag}=#{v}")
      end
      start(argv)
    end

    # Yield [full_colon_path, Command] for every command in this class
    # and all nested namespaces.
    def each_command(prefix = nil, &block)
      commands.each_value do |c|
        full = prefix ? "#{prefix}:#{c.name}" : c.name
        yield full, c
      end
      namespaces.each do |ns_name, sub|
        sub_prefix = prefix ? "#{prefix}:#{ns_name}" : ns_name
        sub.each_command(sub_prefix, &block)
      end
    end

    def run_command(cmd, argv, full: nil)
      # -h / --help is reserved on every command. Anywhere before a `--`
      # stop-marker, it short-circuits to per-command help.
      return print_command_help(cmd, full) if help_requested?(argv)

      positional, opts = Parser.new(cmd.options).parse(argv)
      opts[:args] = positional
      instance = new
      run_before_hooks(instance, opts)
      run_needs(cmd)
      instance.instance_exec(opts, &cmd.handler)
    rescue Parser::Error => e
      Shell.print_error(e.message)
      print_command_help(cmd, full)
      exit 1
    rescue Hammer::Error => e
      # Raised by `error 'msg'` inside a handler - controlled exit, no
      # backtrace, no per-command help spam.
      Shell.print_error(e.message)
      exit 1
    end

    # Fire `before` hooks from root down through the namespace chain.
    # Each class's hooks fire at most once per top-level `start`, so
    # prereqs dispatched via `needs` won't re-trigger them.
    def run_before_hooks(instance, opts)
      ran = Thread.current[:hammer_before_ran] ||= {}
      ancestor_chain.each do |klass|
        next if ran[klass.object_id]
        ran[klass.object_id] = true
        klass.before_hooks.each { |hook| instance.instance_exec(opts, &hook) }
      end
    end

    # Dispatch a command's declared `needs` through the root class, with
    # per-invocation dedupe. Prereqs run with default options (no argv).
    def run_needs(cmd)
      return if cmd.needs.empty?
      ran = Thread.current[:hammer_needs_ran] ||= {}
      cmd.needs.each do |path|
        key = path.to_s
        next if ran[key]
        ran[key] = true
        target, = root.resolve(key)
        raise Error, "needs: unknown command '#{key}' in #{cmd.name}" unless target
        root.start([key])
      end
    end

    def help_requested?(argv)
      stop = argv.index('--')
      scan = stop ? argv[0...stop] : argv
      scan.include?('-h') || scan.include?('--help')
    end

    def print_help(target = nil, full: false)
      if target
        # `help ns:` is equivalent to `ns:` - expanded namespace listing.
        if target.end_with?(':') && target != ':'
          bare = target.chomp(':')
          ns = resolve_namespace(bare)
          return print_namespace_help(bare, ns, full: true) if ns
          Shell.print_error("unknown: #{target}")
          return
        end
        cmd, _ = resolve(target)
        return print_command_help(cmd, target) if cmd
        ns = resolve_namespace(target)
        return print_namespace_help(target, ns, full: full) if ns
        Shell.print_error("unknown: #{target}")
        return
      end

      Shell.say "Usage: #{program_name} COMMAND [ARGS]", :cyan
      if full
        each_command { |path, c| print_full_block(path, c) unless c.desc.empty? }
      else
        Shell.say ''
        print_command_list(self)
      end
      print_footer
    end

    def print_namespace_help(prefix, ns, full: false)
      Shell.say "Usage: #{program_name} #{prefix}:COMMAND [ARGS]", :cyan
      if full
        ns.each_command(prefix) { |path, c| print_full_block(path, c) unless c.desc.empty? }
      else
        Shell.say ''
        print_command_list(ns, prefix)
      end
      print_footer
    end

    # One "task block" for the expanded listing: blank line separator
    # then the standard per-command help (usage + desc + options + examples).
    def print_full_block(path, cmd)
      Shell.say ''
      print_command_help(cmd, path)
    end

    HOMEPAGE ||= 'https://github.com/dux/hammer'.freeze

    def print_footer
      Shell.say ''
      Shell.say "powered by hammer - #{HOMEPAGE}", :gray
    end

    def print_command_list(klass, prefix = nil)
      rows = []
      # Commands without a `desc` are hidden from listings but still
      # dispatchable + `hammer`-callable - useful for private helpers
      # invoked from `before` hooks or other commands (e.g. `:env`, `:app`).
      klass.each_command(prefix) { |full, c| rows << [full, c] unless c.desc.empty? }
      return if rows.empty?

      # group by "section" = everything between the view prefix and the
      # leaf name. Bare leaves go in :root.
      groups = rows.group_by { |full, _| section_for(full, prefix) }
      width  = rows.map { |full, c| label_for(full, c).length }.max
      first  = true

      if (rooted = groups.delete(:root))
        Shell.say 'Commands:', :yellow
        emit_rows(rooted.sort_by { |full, _| full }, width)
        first = false
      end

      groups.each do |section, items|
        Shell.say unless first
        first = false
        Shell.say "#{section}:", :yellow
        emit_rows(items.sort_by { |full, _| full }, width)
      end
    end

    def emit_rows(rows, width)
      rows.each do |full, c|
        label = label_for(full, c)
        Shell.say "  #{program_name} #{label.ljust(width)}  # #{c.brief}"
      end
    end

    # 'db' for 'db:migrate' or 'db:users:list' viewed from root; 'users'
    # for 'db:users:list' viewed from 'db'; :root if the command sits at
    # the view's top level. Only the first segment under the view groups,
    # so deeper paths fold into their top-level section.
    def section_for(full, prefix)
      segs = full.split(':')[0..-2]
      if prefix && !prefix.empty?
        segs = segs[prefix.split(':').size..] || []
      end
      segs.empty? ? :root : segs.first
    end

    # "db:migrate" or "db:migrate (alt: m)"
    def label_for(full, cmd)
      cmd.alts.empty? ? full : "#{full} (alt: #{cmd.alts.join(', ')})"
    end

    # " URL [ENV] [OPTIONS]" - shows the positional-fill names for
    # declared non-boolean opts (required bare, optional bracketed), plus
    # a generic [OPTIONS] tail if any flags exist.
    def usage_signature(cmd)
      pos = cmd.options.reject(&:boolean?).map { |o|
        name = o.name.to_s.upcase
        o.required ? name : "[#{name}]"
      }
      out = pos.join(' ')
      out = "#{out} ".lstrip unless out.empty?
      out += '[OPTIONS]' unless cmd.options.empty?
      out.empty? ? '' : " #{out}"
    end

    def print_command_help(cmd, full = nil)
      full ||= cmd.name
      Shell.say "Usage: #{program_name} #{full}#{usage_signature(cmd)}", :cyan
      cmd.desc.each_line do |line|
        stripped = line.chomp
        Shell.say(stripped.empty? ? '' : "  #{stripped}")
      end unless cmd.desc.empty?
      Shell.say "  alias: #{cmd.alts.join(', ')}" unless cmd.alts.empty?
      unless cmd.options.empty?
        Shell.say ''
        Shell.say 'Options:', :yellow
        cmd.options.each { |o| Shell.say "  #{o.usage}" }
      end
      unless cmd.examples.empty?
        Shell.say ''
        Shell.say 'Examples:', :yellow
        cmd.examples.each { |e| Shell.say "  #{program_name} #{e}" }
      end
    end
  end

  # Inside a command's `proc do |opts| ... end`, call sibling commands:
  #
  #   task :deploy do
  #     proc do |opts|
  #       hammer :build
  #       hammer 'db:migrate', pretend: true
  #     end
  #   end
  #
  # Dispatches from the root class so colon paths resolve against the
  # full tree even when called from inside a namespaced command.
  def hammer(name, *args, **opts)
    self.class.root.hammer(name, *args, **opts)
  end

  # ----- block DSL -----------------------------------------------------

  # Define and run a CLI inline. Inside the block use
  # `task :name do ... end`, `namespace`, and `load`.
  #
  # Without a block: load ./Hammerfile if it exists, otherwise
  # auto-discover *_hammer.rb under Dir.pwd, then dispatch ARGV.
  def self.run(argv = ARGV, &block)
    klass = Class.new(Hammer)
    if block
      Builder.new(klass).instance_eval(&block)
    else
      hf = File.join(Dir.pwd, 'Hammerfile')
      if File.file?(hf)
        Builder.new(klass).instance_eval(File.read(hf), hf)
      else
        klass.loader.load(Dir.pwd, [], auto: true)
      end
    end
    klass.start(argv)
  end

  # Dump the gem's AGENTS.md to stdout - AI-optimized guide for
  # writing Hammerfiles. Bundled with the gem and resolved relative
  # to this file so it works from any install location.
  def self.print_ai_help
    path = File.expand_path('../AGENTS.md', __dir__)
    if File.file?(path)
      puts File.read(path)
    else
      Shell.print_error "AGENTS.md not found at #{path}"
      exit 1
    end
  end

  # Entry point for the `hammer` binary. Walks up from CWD until it
  # finds a Hammerfile, evaluates it as the block DSL, then dispatches
  # ARGV against the resulting CLI.
  #
  # `--ai` is a meta-flag handled here, before Hammerfile lookup,
  # so it works anywhere (no project required).
  def self.cli(argv = ARGV)
    if argv.include?('--ai')
      print_ai_help
      exit 0
    end

    path = find_hammerfile(Dir.pwd)
    unless path
      Shell.print_error "no Hammerfile found in #{Dir.pwd} or any parent directory"

      # Heuristic: *.rb files referencing `Hammer.` are likely inline CLIs
      # the user could promote into a Hammerfile.
      excludes = %w[.git node_modules tmp vendor coverage dist build]
                 .map { |d| "--exclude-dir=#{d}" }.join(' ')
      candidates = `grep -rl --include='*.rb' #{excludes} 'Hammer\\.' . 2>/dev/null`
                   .lines.map(&:strip).reject(&:empty?)
      unless candidates.empty?
        Shell.say "possible CLI implementation(s) - files referencing `Hammer.`:", :yellow
        candidates.first(10).each { |f| Shell.say "  #{f.sub(%r{\A\./}, '')}" }
        Shell.say ''
      end

      Shell.say "create one - example:"
      puts
      Shell.say <<~RUBY
        task :hello do
          desc 'say hello'
          proc do |opts|
            say.green "hello \#{opts[:args].first || 'world'}"
          end
        end
      RUBY
      Shell.say ''
      Shell.say "tip: run `#{File.basename($PROGRAM_NAME)} --ai` for AI-friendly Hammerfile authoring docs", :gray
      exit 1
    end

    klass = Class.new(Hammer)
    # Resolve before chdir so paths like `bin/foo` stay relative to the
    # cwd the user actually invoked from. `program_name` memoizes.
    klass.program_name

    # chdir into the Hammerfile's directory for the entire run so commands
    # operate on the project root (Rake-style).
    Dir.chdir(File.dirname(path))
    Builder.new(klass).instance_eval(File.read(path), path)
    klass.start(argv)
  end

  # Walk up the directory tree looking for a Hammerfile.
  def self.find_hammerfile(start)
    dir = File.expand_path(start)
    loop do
      candidate = File.join(dir, 'Hammerfile')
      return candidate if File.file?(candidate)
      parent = File.dirname(dir)
      return nil if parent == dir
      dir = parent
    end
  end

end
