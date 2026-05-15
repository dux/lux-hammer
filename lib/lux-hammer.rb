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
#     program_name 'mycli'
#
#     define :build do
#       desc    'Build the project'
#       example 'build -v --env=prod'
#       opt :verbose, type: :boolean, alias: :v
#       opt :env,     type: :string,  default: 'dev'
#       proc do |opts|
#         say "building #{opts[:env]} args=#{opts[:args].inspect}", :green
#       end
#     end
#   end
#
#   MyCli.start(ARGV)
#
# Block DSL is identical, just inside `Hammer.run`:
#
#   Hammer.run(ARGV) do
#     program 'inline'
#     define :hello do
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
      sub.instance_variable_set(:@program_name, nil)
      sub.instance_variable_set(:@pending_desc, nil)
      sub.instance_variable_set(:@pending_examples, [])
      sub.instance_variable_set(:@pending_options, [])
      sub.instance_variable_set(:@pending_alts, [])
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

    def method_added(method_name)
      super
      return unless @pending_desc

      cmd = Command.new(name: method_name.to_s, desc: @pending_desc)
      @pending_examples.each { |e| cmd.add_example(e) }
      @pending_options.each  { |o| cmd.add_option(o) }
      @pending_alts.each     { |n| cmd.add_alt(n) }

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
    end

    def program_name(name = nil)
      @program_name = name if name
      @program_name || default_program_name
    end

    # Default shown in help/usage when `program_name` is not set:
    # the invocation path relative to cwd if the script lives inside it
    # (e.g. `bin/foo` when invoked from the project root), otherwise the
    # basename (e.g. `lux` for a globally installed bin in PATH).
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
    def define(name, &block)
      cmd = Command.new(name: name.to_s)
      handler = CommandBuilder.new(cmd).instance_eval(&block)
      unless handler.is_a?(Proc)
        raise Error, <<~MSG
          define(:#{name}) block must end with a `proc do |opts| ... end`.
          The proc's return value is what becomes the command handler.

          Example:

            define :#{name} do
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

      # `define` ignores pending class-level state, but clear it so a
      # later `def` doesn't accidentally consume stale metadata.
      @pending_desc = nil
      @pending_examples = []
      @pending_options  = []
      @pending_alts     = []
    end

    # Open a namespace (group of commands). Everything inside the block
    # (define, nested namespace, program_name override, ...) belongs to
    # that namespace, evaluated against an anonymous Hammer subclass.
    #
    #   namespace :db do
    #     define :migrate do ... end
    #     namespace :users do ... end
    #   end
    def namespace(name, &block)
      sub = Class.new(Hammer)
      # Track the top-level CLI class so cross-invocation
      # (`hammer_<colon_path>`) from inside a namespaced command dispatches
      # against the full tree, not just the current namespace.
      sub.instance_variable_set(:@root, root)
      # Inherit program_name so help banners show "myapp ns:cmd", not
      # whichever binary the namespace class fell back to.
      sub.program_name(program_name) if @program_name
      sub.class_eval(&block) if block
      @namespaces[name.to_s] = sub
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
    def start(argv = ARGV)
      argv = argv.dup
      name = argv.shift

      if name.nil? || name == 'help' || name == '-h' || name == '--help'
        target = argv.shift
        return print_help(target)
      end

      cmd, owner = resolve(name)
      return owner.run_command(cmd, argv, full: name) if cmd

      ns = resolve_namespace(name)
      return print_namespace_help(name, ns) if ns

      Shell.print_error("unknown command: #{name}")
      print_help
      exit 1
    end

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

    # MyCli.hammer_db_users_list("a", verbose: true) ->
    # MyCli.start(["db:users:list", "a", "--verbose"])
    #
    # Useful for scripting and tests. Underscores in the method name map
    # to colons; underscores in kwarg keys map to dashes in the flag.
    def method_missing(name, *args, **kwargs, &block)
      str = name.to_s
      return super unless str.start_with?('hammer_')

      path = str.sub(/^hammer_/, '').tr('_', ':')
      argv = [path, *args.map(&:to_s)]
      # kwarg key mirrors the CLI flag literally:
      #   verbose: true       -> --verbose
      #   no_cache: true      -> --no-cache  (just the general rule)
      #   env: 'prod'         -> --env=prod
      #   anything: false     -> skipped (no-op; use `no_x: true` to negate)
      kwargs.each do |k, v|
        next if v == false
        flag = "--#{k.to_s.tr('_', '-')}"
        argv << (v == true ? flag : "#{flag}=#{v}")
      end
      start(argv)
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.start_with?('hammer_') || super
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

    def help_requested?(argv)
      stop = argv.index('--')
      scan = stop ? argv[0...stop] : argv
      scan.include?('-h') || scan.include?('--help')
    end

    def print_help(target = nil)
      if target
        cmd, _ = resolve(target)
        return print_command_help(cmd, target) if cmd
        ns = resolve_namespace(target)
        return print_namespace_help(target, ns) if ns
        Shell.print_error("unknown: #{target}")
        return
      end

      Shell.say "Usage: #{program_name} COMMAND [ARGS]", :cyan
      Shell.say ''
      print_command_list(self)
      print_footer
    end

    def print_namespace_help(prefix, ns)
      Shell.say "Usage: #{program_name} #{prefix}:COMMAND [ARGS]", :cyan
      Shell.say ''
      print_command_list(ns, prefix)
      print_footer
    end

    HOMEPAGE ||= 'https://github.com/dux/hammer'.freeze

    def print_footer
      Shell.say ''
      Shell.say "powered by hammer - #{HOMEPAGE}", :gray
    end

    def print_command_list(klass, prefix = nil)
      rows = []
      klass.each_command(prefix) { |full, c| rows << [full, c] }
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
  #   define :deploy do
  #     proc do |opts|
  #       hammer_build
  #       hammer_db_migrate(pretend: true)
  #     end
  #   end
  def method_missing(name, *args, **kwargs, &block)
    return super unless name.to_s.start_with?('hammer_')
    # Dispatch from the root class so `hammer_a_b` resolves against the
    # full colon path "a:b" even when called inside a namespaced command
    # (where self.class would be the namespace subclass).
    self.class.root.send(name, *args, **kwargs, &block)
  end

  def respond_to_missing?(name, include_private = false)
    name.to_s.start_with?('hammer_') || super
  end

  # ----- block DSL -----------------------------------------------------

  # Define and run a CLI inline. Inside the block use `program`,
  # `define :name do ... end`, and `namespace`.
  def self.run(argv = ARGV, &block)
    klass = Class.new(Hammer)
    Builder.new(klass).instance_eval(&block)
    klass.start(argv)
  end

  # Entry point for the `hammer` binary. Walks up from CWD until it
  # finds a Hammerfile, evaluates it as the block DSL, then dispatches
  # ARGV against the resulting CLI.
  def self.cli(argv = ARGV)
    path = find_hammerfile(Dir.pwd)
    unless path
      Shell.print_error "no Hammerfile found in #{Dir.pwd} or any parent directory"
      Shell.say "create one - example:"
      Shell.say <<~RUBY
        program 'mycli'

        define :hello do
          desc 'say hello'
          proc { |opts| say "hello \#{opts[:args].first || 'world'}", :green }
        end
      RUBY
      exit 1
    end

    klass = Class.new(Hammer)
    # Resolve before chdir so paths like `bin/foo` stay relative to the
    # cwd the user actually invoked from.
    klass.program_name(klass.default_program_name)

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
