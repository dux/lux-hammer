require_relative 'test_helper'

class RecipeTest < Minitest::Test
  include CaptureIO

  # Each test gets a fresh tmpdir as the user recipes dir so the gem's
  # real recipes (in <gem>/recipes/) never bleed in unless we want them.
  def with_user_dir(present:, &block)
    Dir.mktmpdir do |dir|
      if present
        ENV['HAMMER_RECIPES_DIR'] = dir
      else
        ENV['HAMMER_RECIPES_DIR'] = File.join(dir, 'does-not-exist')
      end
      yield(dir)
    ensure
      ENV.delete('HAMMER_RECIPES_DIR')
    end
  end

  def test_desc_reads_first_desc_comment_line
    with_user_dir(present: true) do |dir|
      file = File.join(dir, 'foo.rb')
      File.write(file, <<~RUBY)
        # desc: my foo recipe
        # other comment
        task :x do
          desc 'X'
          proc { |_| }
        end
      RUBY
      assert_equal 'my foo recipe', Hammer::Recipe.desc(file)
    end
  end

  def test_desc_ignores_lines_past_first_match
    with_user_dir(present: true) do |dir|
      file = File.join(dir, 'foo.rb')
      File.write(file, <<~RUBY)
        # desc: real one
        # desc: should be ignored
      RUBY
      assert_equal 'real one', Hammer::Recipe.desc(file)
    end
  end

  def test_desc_returns_empty_when_absent
    with_user_dir(present: true) do |dir|
      file = File.join(dir, 'foo.rb')
      File.write(file, "task :x do; proc { |_| }; end\n")
      assert_equal '', Hammer::Recipe.desc(file)
    end
  end

  def test_all_discovers_user_dir_entries
    with_user_dir(present: true) do |dir|
      File.write(File.join(dir, 'alpha.rb'), '# desc: a')
      File.write(File.join(dir, 'beta.rb'),  '# desc: b')
      assert_equal %w[alpha beta], Hammer::Recipe.all.keys.sort & %w[alpha beta]
    end
  end

  def test_user_dir_overrides_gem_dir_on_collision
    with_user_dir(present: true) do |dir|
      # srt.rb exists in the gem's recipes; shadow it from the user dir.
      shadow = File.join(dir, 'srt.rb')
      File.write(shadow, '# desc: my override')
      assert_equal shadow, Hammer::Recipe.path('srt')
      assert_equal 'my override', Hammer::Recipe.desc(Hammer::Recipe.path('srt'))
    end
  end

  def test_stub_is_valid_ruby_and_embeds_name
    out = Hammer::Recipe.stub('myname')
    assert_includes out, "Hammer.recipe('myname', ARGV)"
    assert_includes out, "#!/usr/bin/env ruby"
    # Syntax check: parse without executing.
    assert RubyVM::InstructionSequence.compile(out)
  end

  def test_stub_handles_hyphenated_names
    out = Hammer::Recipe.stub('git-helper')
    assert_includes out, "Hammer.recipe('git-helper', ARGV)"
    # `:git-helper` is invalid as a bare symbol literal; quoted string isn't.
    assert RubyVM::InstructionSequence.compile(out)
  end

  def test_installed_path_detects_stub_in_path
    Dir.mktmpdir do |bindir|
      bin = File.join(bindir, 'foo')
      File.write(bin, Hammer::Recipe.stub('foo'))
      File.chmod(0o755, bin)
      orig = ENV['PATH']
      ENV['PATH'] = "#{bindir}#{File::PATH_SEPARATOR}#{orig}"
      assert_equal bin, Hammer::Recipe.installed_path('foo')
    ensure
      ENV['PATH'] = orig
    end
  end

  def test_installed_path_ignores_unrelated_binaries
    Dir.mktmpdir do |bindir|
      bin = File.join(bindir, 'bar')
      File.write(bin, "#!/bin/sh\necho hi\n")
      File.chmod(0o755, bin)
      orig = ENV['PATH']
      ENV['PATH'] = "#{bindir}#{File::PATH_SEPARATOR}#{orig}"
      assert_nil Hammer::Recipe.installed_path('bar')
    ensure
      ENV['PATH'] = orig
    end
  end

  def test_recipe_entry_runs_with_program_name_set
    with_user_dir(present: true) do |dir|
      File.write(File.join(dir, 'echo.rb'), <<~RUBY)
        # desc: echo helper
        task :hi do
          desc 'say hi'
          proc { |_| say 'hello from echo' }
        end
      RUBY
      out, = capture { Hammer.recipe(:echo, ['hi']) }
      assert_includes out, 'hello from echo'

      out, = capture { Hammer.recipe(:echo, ['--help']) }
      assert_includes out, 'Usage: echo'
      assert_includes out, 'echo hi'
    end
  end

  def test_recipe_unknown_name_exits_1
    with_user_dir(present: false) do
      _, err, status = capture_exit { Hammer.recipe(:nope, []) }
      assert_equal 1, status
      assert_includes err, 'unknown recipe: nope'
    end
  end
end
