require_relative 'test_helper'

class LoadTest < Minitest::Test
  include CaptureIO

  def with_proj
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def make_cli
    Class.new(Hammer) { program_name 'tcli' }
  end

  def test_load_explicit_file
    with_proj do |dir|
      file = File.join(dir, 'db_hammer.rb')
      write(file, <<~RUBY)
        define :migrate do
          desc 'Migrate'
          proc { |_| }
        end
      RUBY
      cli = make_cli
      cli.load(file)
      assert cli.commands.key?('migrate')
    end
  end

  def test_load_glob
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), "define(:a) { desc 'A'; proc { |_| } }\n")
      write(File.join(dir, 'b_hammer.rb'), "define(:b) { desc 'B'; proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, ['*_hammer.rb'], {})
      assert cli.commands.key?('a')
      assert cli.commands.key?('b')
    end
  end

  def test_load_auto_recursive
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), "define(:a) { proc { |_| } }\n")
      write(File.join(dir, 'sub/b_hammer.rb'), "define(:b) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], {})
      assert cli.commands.key?('a')
      assert cli.commands.key?('b')
    end
  end

  def test_load_auto_kwarg_equivalent_to_bare
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), "define(:a) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], { auto: true })
      assert cli.commands.key?('a')
    end
  end

  def test_auto_false_is_noop
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), "define(:a) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], { auto: false })
      refute cli.commands.key?('a')
    end
  end

  def test_skipped_dirs_are_ignored
    with_proj do |dir|
      write(File.join(dir, 'good_hammer.rb'), "define(:good) { proc { |_| } }\n")
      write(File.join(dir, 'node_modules/x_hammer.rb'), "define(:bad) { proc { |_| } }\n")
      write(File.join(dir, '.git/y_hammer.rb'), "define(:bad2) { proc { |_| } }\n")
      write(File.join(dir, 'tmp/z_hammer.rb'), "define(:bad3) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], {})
      assert cli.commands.key?('good')
      refute cli.commands.key?('bad')
      refute cli.commands.key?('bad2')
      refute cli.commands.key?('bad3')
    end
  end

  def test_only_files_ending_in_hammer_rb_are_picked_up
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), "define(:a) { proc { |_| } }\n")
      write(File.join(dir, 'helpers.rb'),  "define(:should_not_register) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], {})
      assert cli.commands.key?('a')
      refute cli.commands.key?('should_not_register')
    end
  end

  def test_dedup_same_file_loaded_once
    with_proj do |dir|
      file = File.join(dir, 'x_hammer.rb')
      write(file, "define(:x) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], {})
      cli.loader.load(dir, [], {})
      assert_equal 1, cli.loader.loaded.size
    end
  end

  def test_reentrant_load
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), <<~RUBY)
        load 'b_hammer.rb'
        define(:a) { proc { |_| } }
      RUBY
      write(File.join(dir, 'b_hammer.rb'), "define(:b) { proc { |_| } }\n")
      cli = make_cli
      cli.loader.load(dir, [], {})
      assert cli.commands.key?('a')
      assert cli.commands.key?('b')
    end
  end

  def test_fragment_error_surfaces_with_path
    with_proj do |dir|
      file = File.join(dir, 'bad_hammer.rb')
      write(file, "raise 'boom'\n")
      cli = make_cli
      err = assert_raises(Hammer::Error) { cli.loader.load(dir, [], {}) }
      assert_includes err.message, 'failed loading'
      assert_includes err.message, 'bad_hammer.rb'
      assert_includes err.message, 'boom'
    end
  end

  def test_no_files_matched_raises
    with_proj do |dir|
      cli = make_cli
      err = assert_raises(Hammer::Error) { cli.loader.load(dir, ['nope_*.rb'], {}) }
      assert_includes err.message, 'no files matched'
    end
  end

  def test_auto_silent_on_zero_files
    with_proj do |dir|
      cli = make_cli
      cli.loader.load(dir, [], {})
      assert_empty cli.commands
    end
  end

  def test_unknown_option_raises
    with_proj do |dir|
      cli = make_cli
      err = assert_raises(Hammer::Error) { cli.loader.load(dir, [], { bogus: 1 }) }
      assert_includes err.message, 'unknown option'
    end
  end

  def test_base_class_load_raises
    err = assert_raises(Hammer::Error) { Hammer.load('x.rb') }
    assert_includes err.message, 'no target'
  end

  def test_fragment_can_define_namespaces
    with_proj do |dir|
      write(File.join(dir, 'db_hammer.rb'), <<~RUBY)
        namespace :db do
          define :migrate do
            desc 'Run migrations'
            proc { |_| }
          end
        end
      RUBY
      cli = make_cli
      cli.loader.load(dir, [], {})
      cmd, _owner = cli.resolve('db:migrate')
      refute_nil cmd
    end
  end

  def test_load_via_builder_uses_caller_anchor
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), "define(:a) { proc { |_| } }\n")
      cli = Class.new(Hammer)
      Hammer::Builder.new(cli).load(File.join(dir, 'a_hammer.rb'))
      assert cli.commands.key?('a')
    end
  end

  def test_cross_file_invocation_works
    with_proj do |dir|
      write(File.join(dir, 'a_hammer.rb'), <<~RUBY)
        namespace :db do
          define :migrate do
            proc { |_| $log << :migrated }
          end
        end
      RUBY
      write(File.join(dir, 'b_hammer.rb'), <<~RUBY)
        define :deploy do
          proc do |_|
            hammer_db_migrate
            $log << :deployed
          end
        end
      RUBY
      cli = make_cli
      cli.loader.load(dir, [], {})
      $log = []
      capture { cli.start(['deploy']) }
      assert_equal [:migrated, :deployed], $log
    ensure
      $log = nil
    end
  end

  def test_hammerfile_can_call_load
    with_proj do |dir|
      write(File.join(dir, 'Hammerfile'), <<~RUBY)
        program 'demo'
        load auto: true
      RUBY
      write(File.join(dir, 'tasks/db_hammer.rb'), <<~RUBY)
        define :migrate do
          desc 'Migrate'
          proc { |_| say 'migrated' }
        end
      RUBY
      Dir.chdir(dir) do
        out, _ = capture { Hammer.cli(['help']) }
        assert_includes out, 'demo migrate'
      end
    end
  end
end
