require_relative 'test_helper'

class BuiltinsTest < Minitest::Test
  include CaptureIO

  def with_hammerfile(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Hammerfile'), content)
      Dir.chdir(dir) { yield dir }
    end
  end

  # ----- trigger detection -------------------------------------------

  def test_triggered_on_help_variants
    assert Hammer.builtins_triggered?([])
    assert Hammer.builtins_triggered?(['--help'])
    assert Hammer.builtins_triggered?(['-h'])
    assert Hammer.builtins_triggered?(['help'])
  end

  def test_triggered_on_self_prefix
    assert Hammer.builtins_triggered?(['self:ai'])
    assert Hammer.builtins_triggered?(['self:recipe', 'install', 'srt'])
    assert Hammer.builtins_triggered?(['self'])
  end

  def test_not_triggered_on_user_commands
    refute Hammer.builtins_triggered?(['build'])
    refute Hammer.builtins_triggered?(['db:migrate'])
    refute Hammer.builtins_triggered?(['hello', 'dino', '--loud'])
  end

  # ----- reserved-name guard -----------------------------------------

  def test_user_namespace_self_is_rejected
    err = assert_raises(Hammer::Error) do
      Class.new(Hammer) do
        namespace :self do
          task :foo do
            proc { |_| }
          end
        end
      end
    end
    assert_includes err.message, "reserved"
  end

  def test_builtins_register_passes_the_guard
    klass = Class.new(Hammer)
    klass.instance_variable_set(:@hammer_binary, true)
    Hammer::Builtins.register(klass)
    assert klass.namespaces.key?('self')
    assert klass.namespaces['self'].commands.key?('ai')
    assert klass.namespaces['self'].commands.key?('update')
    assert klass.namespaces['self'].commands.key?('recipe')
  end

  # ----- self:recipe action dispatch ---------------------------------

  def test_self_recipe_list_runs_without_args
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['self:recipe']) }
      # srt is bundled with the gem so the listing must mention it.
      assert_includes out, 'srt'
    end
  end

  def test_self_recipe_install_prints_stub
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['self:recipe', 'install', 'srt']) }
      assert_includes out, "Hammer.recipe('srt', ARGV)"
      assert_includes out, '#!/usr/bin/env ruby'
    end
  end

  def test_self_recipe_install_with_target_writes_and_chmods
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'srt')
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        out, = capture { Hammer.cli(['self:recipe', 'install', 'srt', target]) }
        assert_includes out, "installed srt -> #{target}"
      end
      assert File.exist?(target)
      assert File.executable?(target)
      assert_includes File.read(target), "Hammer.recipe('srt', ARGV)"
    end
  end

  def test_self_recipe_install_with_target_expands_tilde
    # Use HOME under a tmpdir so the test doesn't touch the real home.
    Dir.mktmpdir do |home|
      bin = File.join(home, 'bin')
      Dir.mkdir(bin)
      orig_home = ENV['HOME']
      ENV['HOME'] = home
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        capture { Hammer.cli(['self:recipe', 'install', 'srt', '~/bin/srt']) }
      end
      assert File.exist?(File.join(bin, 'srt'))
    ensure
      ENV['HOME'] = orig_home
    end
  end

  def test_self_recipe_path_prints_path
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['self:recipe', 'path', 'srt']) }
      assert_includes out, 'recipes/srt.rb'
    end
  end

  def test_self_recipe_show_cats_source
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['self:recipe', 'show', 'srt']) }
      assert_includes out, '# desc:'
      assert_includes out, 'task :'
    end
  end

  def test_self_recipe_unknown_action_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['self:recipe', 'frobnicate']) }
      assert_equal 1, status
      assert_includes err, 'unknown action: frobnicate'
    end
  end

  def test_self_recipe_run_dispatches_to_recipe
    # Drop a fake recipe in a temp HAMMER_RECIPES_DIR so we can observe
    # the dispatch without shelling out to the real bundled recipes.
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'echo.rb'), <<~RUBY)
        # desc: echo recipe
        task :hi do
          desc 'say hi'
          proc { say 'reached the recipe' }
        end
      RUBY
      ENV['HAMMER_RECIPES_DIR'] = dir
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        out, = capture { Hammer.cli(['self:recipe', 'run', 'echo', 'hi']) }
        assert_includes out, 'reached the recipe'
      end
    ensure
      ENV.delete('HAMMER_RECIPES_DIR')
    end
  end

  def test_self_recipe_run_without_name_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['self:recipe', 'run']) }
      assert_equal 1, status
      assert_includes err, 'missing recipe name'
    end
  end

  def test_self_recipe_missing_name_for_show_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['self:recipe', 'show']) }
      assert_equal 1, status
      assert_includes err, 'missing recipe name'
    end
  end

  # ----- --update flag alias -----------------------------------------

  def test_update_flag_rewrites_to_self_update
    # Hammer.self_update would actually shell out to git; we stub it.
    called = false
    Hammer.singleton_class.send(:alias_method, :__orig_self_update, :self_update)
    Hammer.define_singleton_method(:self_update) { called = true }

    with_hammerfile("task :x do; proc { |_| }; end\n") do
      capture { Hammer.cli(['--update']) }
    end
    assert called, '--update should dispatch to Hammer.self_update via self:update'
  ensure
    Hammer.define_singleton_method(:self_update) { __orig_self_update }
    Hammer.singleton_class.send(:remove_method, :__orig_self_update) if Hammer.singleton_class.method_defined?(:__orig_self_update)
  end

  # ----- Recipes: section in help ------------------------------------

  def test_help_includes_recipes_section
    with_hammerfile("task :x do; desc 'X'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--help']) }
      assert_includes out, 'Recipes:'
      assert_includes out, 'srt'
    end
  end
end
