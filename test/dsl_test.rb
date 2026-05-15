require_relative 'test_helper'

class DslTest < Minitest::Test
  include CaptureIO

  # ----- class DSL ----------------------------------------------------

  def build_cli(&block)
    Class.new(Hammer) do
      program_name 'mycli'
      instance_eval(&block)
    end
  end

  def test_def_style_command
    captured = nil
    cli = Class.new(Hammer) do
      program_name 'mycli'
      desc 'Build'
      opt :env, default: 'dev'
      define_method(:build) { |opts| captured = opts }
    end
    capture { cli.start(%w[build prod]) }
    assert_equal 'prod', captured[:env]
  end

  def test_def_style_alt_and_example
    cli = Class.new(Hammer) do
      program_name 'mycli'
      desc 'Server'
      example 'server -p 4000'
      alt :s
      define_method(:server) { |opts| }
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'mycli server (alt: s)'
    assert_includes out, 'Server'
  end

  def test_def_with_no_args_is_called_without_opts
    log = []
    cli = Class.new(Hammer) do
      program_name 'mycli'
      desc 'Ping'
      define_method(:ping) { log << :pong }
    end
    capture { cli.start(['ping']) }
    assert_equal [:pong], log
  end

  def test_def_without_desc_is_just_a_method
    cli = Class.new(Hammer) do
      program_name 'mycli'
      define_method(:helper) { 42 }
    end
    refute cli.commands.key?('helper')
  end

  def test_def_and_define_can_coexist
    log = []
    cli = Class.new(Hammer) do
      program_name 'mycli'

      desc 'def-style command'
      define_method(:foo) { |_| log << :foo }

      define :bar do
        desc 'block-style command'
        proc { |_| log << :bar }
      end
    end
    capture { cli.start(['foo']) }
    capture { cli.start(['bar']) }
    assert_equal [:foo, :bar], log
  end

  def test_pending_desc_does_not_leak_across_define
    log = []
    cli = Class.new(Hammer) do
      program_name 'mycli'
      desc 'should be cleared'
      define :first do
        proc { |_| log << :first }
      end
      # No desc here - foo should NOT become a command
      define_method(:foo) { |_| log << :foo }
    end
    refute cli.commands.key?('foo')
    assert cli.commands.key?('first')
  end

  def test_define_registers_command
    captured = nil
    cli = build_cli do
      define :build do
        desc 'Build'
        opt :env, default: 'dev'
        proc { |opts| captured = opts }
      end
    end
    capture { cli.start(%w[build --env=prod a b]) }
    refute_nil captured
    assert_equal 'prod', captured[:env]
    assert_equal %w[a b], captured[:args]
  end

  def test_opts_all_symbol_keys
    seen = nil
    cli = build_cli do
      define :x do
        opt :env, default: 'dev'
        opt :loud, type: :boolean
        proc { |opts| seen = opts }
      end
    end
    capture { cli.start(%w[x --env=prod --loud foo]) }
    assert_equal [:env, :loud, :args], seen.keys
    assert(seen.keys.all? { |k| k.is_a?(Symbol) })
    assert_equal 'prod', seen[:env]
    assert_equal true,   seen[:loud]
    assert_equal ['foo'], seen[:args]
  end

  def test_block_must_end_with_proc
    err = assert_raises(Hammer::Error) do
      build_cli { define(:bad) { desc 'no proc here' } }
    end
    assert_includes err.message, 'must end with'
  end

  def test_missing_proc_error_includes_example
    err = assert_raises(Hammer::Error) do
      build_cli { define(:greet) { desc 'hi' } }
    end
    assert_includes err.message, 'Example:'
    assert_includes err.message, 'define :greet do'
    assert_includes err.message, 'proc do |opts|'
  end

  def test_help_groups_by_namespace
    cli = build_cli do
      define :build do
        desc 'Build'
        proc { |_| }
      end
      namespace :db do
        define :migrate do
          desc 'Migrate'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['help']) }
    # commands section appears before db: section
    cmd_idx = out.index('Commands:')
    db_idx  = out.index("db:\n")
    refute_nil cmd_idx
    refute_nil db_idx
    assert cmd_idx < db_idx
  end

  def test_option_help_shows_default_and_required
    cli = build_cli do
      define :run do
        opt :env, default: 'dev'
        opt :url, req: true
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help run]) }
    assert_includes out, '(default: "dev")'
    assert_includes out, '(required)'
  end

  def test_command_usage_shows_positional_opt_names
    cli = build_cli do
      define :deploy do
        opt :url, req: true
        opt :env
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help deploy]) }
    assert_includes out, 'mycli deploy URL [ENV] [OPTIONS]'
  end

  def test_alt_dispatches
    hits = []
    cli = build_cli do
      define :server do
        alt :s, :srv
        proc { |_| hits << :ran }
      end
    end
    capture { cli.start(['server']) }
    capture { cli.start(['s']) }
    capture { cli.start(['srv']) }
    assert_equal [:ran, :ran, :ran], hits
  end

  def test_unknown_command_exits_1
    cli = build_cli { define(:x) { proc { |_| } } }
    _, err, status = capture_exit { cli.start(['bogus']) }
    assert_equal 1, status
    assert_includes err, 'unknown command'
  end

  def test_help_prints_github_footer
    cli = build_cli { define(:x) { desc 'X'; proc { |_| } } }
    out, = capture { cli.start(['help']) }
    assert_includes out, 'powered by hammer'
    assert_includes out, 'https://github.com/dux/hammer'
  end

  def test_help_lists_commands_with_alts
    cli = build_cli do
      define :build do
        desc 'Build'
        proc { |_| }
      end
      define :server do
        desc 'Server'
        alt :s
        proc { |_| }
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'mycli build'
    assert_includes out, 'mycli server (alt: s)'
    assert_includes out, 'Build'
    assert_includes out, 'Server'
  end

  def test_per_command_help
    cli = build_cli do
      define :build do
        desc 'Build the project'
        example 'build -v'
        opt :verbose, type: :boolean, alias: :v
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help build]) }
    assert_includes out, 'Build the project'
    assert_includes out, '--verbose'
    assert_includes out, '-v'
    assert_includes out, 'Examples:'
    assert_includes out, 'mycli build -v'
  end

  def test_help_via_dash_h
    cli = build_cli { define(:x) { desc 'X'; proc { |_| } } }
    out, = capture { cli.start(['-h']) }
    assert_includes out, 'Usage:'
  end

  def test_dash_h_after_command_shows_command_help
    ran = false
    cli = build_cli do
      define :build do
        desc 'Build the project'
        opt :env, default: 'dev'
        proc { |_| ran = true }
      end
    end
    out, = capture { cli.start(%w[build -h]) }
    assert_includes out, 'Usage: mycli build'
    assert_includes out, 'Build the project'
    refute ran, 'handler must not run when -h is present'
  end

  def test_long_help_flag_after_command
    ran = false
    cli = build_cli do
      define :build do
        proc { |_| ran = true }
      end
    end
    capture { cli.start(%w[build --help]) }
    refute ran
  end

  def test_help_after_namespaced_command_shows_full_path
    cli = build_cli do
      namespace :gem do
        define :inc_version do
          desc 'Bump version'
          opt :bump, default: 'patch'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(%w[gem:inc_version -h]) }
    assert_includes out, 'Usage: mycli gem:inc_version'
  end

  def test_parser_error_help_uses_full_path
    cli = build_cli do
      namespace :gem do
        define :inc_version do
          opt :bump
          proc { |_| }
        end
      end
    end
    out, err, _ = capture_exit { cli.start(%w[gem:inc_version --bogus]) }
    assert_includes err, 'unknown option'
    assert_includes out, 'mycli gem:inc_version'
  end

  def test_double_dash_keeps_minus_h_as_positional
    captured = nil
    cli = build_cli do
      define :x do
        proc { |opts| captured = opts[:args] }
      end
    end
    capture { cli.start(['x', '--', '-h']) }
    assert_equal ['-h'], captured
  end

  def test_help_flag_as_opt_name_raises
    assert_raises(Hammer::Error) do
      Hammer::Option.new(:help)
    end
  end

  def test_help_flag_as_alias_raises
    assert_raises(Hammer::Error) do
      Hammer::Option.new(:host, alias: :h)
    end
  end

  def test_namespace_dispatch_via_colon_path
    captured = nil
    cli = build_cli do
      namespace :db do
        define :migrate do
          proc { |opts| captured = opts[:args] }
        end
      end
    end
    capture { cli.start(%w[db:migrate 3]) }
    assert_equal ['3'], captured
  end

  def test_help_lists_namespaced_commands_with_colons
    cli = build_cli do
      define :build do
        desc 'Build'
        proc { |_| }
      end
      namespace :db do
        define :migrate do
          desc 'Run migrations'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'mycli build'
    assert_includes out, 'mycli db:migrate'
  end

  def test_help_for_namespace_lists_contents
    cli = build_cli do
      namespace :db do
        define :migrate do
          desc 'Run migrations'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(%w[help db]) }
    assert_includes out, 'mycli db:migrate'
  end

  def test_bare_namespace_is_implicit_help
    cli = build_cli do
      namespace :db do
        define :migrate do
          desc 'Run migrations'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['db']) }
    assert_includes out, 'mycli db:migrate'
  end

  def test_nested_namespace_dispatch
    captured = nil
    cli = build_cli do
      namespace :db do
        namespace :users do
          define :list do
            proc { |opts| captured = opts[:args] }
          end
        end
      end
    end
    capture { cli.start(%w[db:users:list active admins]) }
    assert_equal %w[active admins], captured
  end

  def test_hammer_method_missing_invokes_command_from_proc
    log = []
    cli = build_cli do
      define :build do
        opt :env, default: 'dev'
        proc { |opts| log << [:build, opts[:env]] }
      end
      define :deploy do
        proc do |_|
          hammer_build(env: 'prod')
          log << [:deploy]
        end
      end
    end
    capture { cli.start(['deploy']) }
    assert_equal [[:build, 'prod'], [:deploy]], log
  end

  def test_hammer_method_missing_resolves_namespaced_via_underscores
    log = []
    cli = build_cli do
      namespace :db do
        namespace :users do
          define :list do
            proc { |opts| log << opts[:args] }
          end
        end
      end
    end
    capture { cli.hammer_db_users_list('a', 'b') }
    assert_equal [%w[a b]], log
  end

  def test_hammer_kwargs_become_flags
    captured = nil
    cli = build_cli do
      define :show do
        opt :env
        opt :loud, type: :boolean
        proc { |opts| captured = opts }
      end
    end
    capture { cli.hammer_show(env: 'prod', loud: true) }
    assert_equal 'prod', captured[:env]
    assert_equal true,   captured[:loud]
  end

  def test_hammer_no_prefix_kwarg_emits_negation
    captured = nil
    cli = build_cli do
      define :show do
        opt :cache, type: :boolean, default: true
        proc { |opts| captured = opts[:cache] }
      end
    end
    capture { cli.hammer_show(no_cache: true) }
    assert_equal false, captured
  end

  def test_hammer_false_kwarg_is_noop
    captured = nil
    cli = build_cli do
      define :show do
        opt :cache, type: :boolean, default: true
        proc { |opts| captured = opts[:cache] }
      end
    end
    capture { cli.hammer_show(cache: false) }
    # default sticks - false-valued kwargs are skipped entirely
    assert_equal true, captured
  end

  def test_hammer_underscore_in_kwarg_becomes_dash
    captured = nil
    cli = build_cli do
      define :show do
        opt :dry_run, type: :boolean
        proc { |opts| captured = opts[:dry_run] }
      end
    end
    capture { cli.hammer_show(dry_run: true) }
    assert_equal true, captured
  end

  def test_non_hammer_method_still_raises
    cli = build_cli { define(:x) { proc { |_| } } }
    assert_raises(NoMethodError) { cli.something_else }
  end

  def test_alt_inside_namespace
    captured = nil
    cli = build_cli do
      namespace :db do
        define :migrate do
          alt :m
          proc { |opts| captured = opts[:args] }
        end
      end
    end
    capture { cli.start(%w[db:m 5]) }
    assert_equal ['5'], captured
  end

  def test_error_inside_proc_exits_1_with_message
    cli = build_cli do
      define :doomed do
        proc { |_| error 'boom' }
      end
    end
    out, err, status = capture_exit { cli.start(['doomed']) }
    assert_equal 1, status
    assert_includes err, 'boom'
    assert_includes err, '[error]'
    # no command help spam on user-raised errors
    refute_includes out, 'Usage:'
  end

  def test_parser_error_exits_1
    cli = build_cli do
      define :x do
        opt :env, type: :string, req: true
        proc { |_| }
      end
    end
    _, err, status = capture_exit { cli.start(['x']) }
    assert_equal 1, status
    assert_includes err, 'missing required'
  end

  # ----- block DSL ----------------------------------------------------

  def test_block_dsl_run
    captured = nil
    capture do
      Hammer.run(%w[hello dino -l]) do
        program 'inline'
        define :hello do
          opt :loud, type: :boolean, alias: :l
          proc { |opts| captured = opts }
        end
      end
    end
    assert_equal true, captured[:loud]
    assert_equal ['dino'], captured[:args]
  end

  def test_block_dsl_alt
    hits = []
    capture do
      Hammer.run(['s']) do
        program 'x'
        define :server do
          alt :s
          proc { |_| hits << :ok }
        end
      end
    end
    assert_equal [:ok], hits
  end
end
