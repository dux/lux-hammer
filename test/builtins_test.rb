require_relative 'test_helper'
require 'hammer/builtins'

class BuiltinsTest < Minitest::Test
  include CaptureIO

  def with_hammerfile(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Hammerfile'), content)
      Dir.chdir(dir) { yield dir }
    end
  end

  # ----- trigger detection -------------------------------------------

  def test_wants_self_namespace_on_help_variants
    # Explicit help requests should surface `self:` and `Recipes:` so
    # users can discover tool-meta commands.
    assert Hammer.wants_self_namespace?(['--help'])
    assert Hammer.wants_self_namespace?(['-h'])
    assert Hammer.wants_self_namespace?(['help'])
  end

  def test_wants_self_namespace_on_self_prefix
    assert Hammer.wants_self_namespace?(['self:ai'])
    assert Hammer.wants_self_namespace?(['self:recipe', 'install', 'srt'])
    assert Hammer.wants_self_namespace?(['self'])
  end

  def test_wants_self_namespace_skipped_on_bare_or_user_commands
    # Bare `hammer` and user commands keep listings clean - no `self:`
    # leak. Lazy-load avoids polluting normal project views.
    refute Hammer.wants_self_namespace?([])
    refute Hammer.wants_self_namespace?(['build'])
    refute Hammer.wants_self_namespace?(['db:migrate'])
    refute Hammer.wants_self_namespace?(['hello', 'dino', '--loud'])
  end

  def test_dispatches_to_builtin_for_bare_and_flag_and_help
    assert Hammer.dispatches_to_builtin?([])
    assert Hammer.dispatches_to_builtin?(['--version'])
    assert Hammer.dispatches_to_builtin?(['-v'])
    assert Hammer.dispatches_to_builtin?(['--update'])
    assert Hammer.dispatches_to_builtin?(['help'])
    assert Hammer.dispatches_to_builtin?(['-h'])
    assert Hammer.dispatches_to_builtin?(['--help'])
    refute Hammer.dispatches_to_builtin?(['build'])
    refute Hammer.dispatches_to_builtin?(['db:migrate'])
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

  def test_register_self_passes_the_guard
    klass = Class.new(Hammer)
    klass.instance_variable_set(:@hammer_binary, true)
    Hammer::Builtins.register_self(klass)
    assert klass.namespaces.key?('self')
    assert klass.namespaces['self'].commands.key?('ai')
    assert klass.namespaces['self'].commands.key?('update')
    assert klass.namespaces['self'].commands.key?('recipe')
  end

  def test_register_core_adds_default_and_help
    klass = Class.new(Hammer)
    Hammer::Builtins.register_core(klass)
    assert klass.commands.key?('default')
    assert klass.commands.key?('help')
  end

  def test_register_core_skips_when_user_defined
    klass = Class.new(Hammer) do
      task :default do
        proc { |_| say 'mine' }
      end
      task :help do
        desc 'my help'
        proc { |_| say 'my help' }
      end
    end
    Hammer::Builtins.register_core(klass)
    # User definitions still in place (no redefinition warning fires
    # because register_core guards on commands.key?).
    assert_equal 'my help', klass.commands['help'].desc
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

  # ----- self: + Recipes: visibility contract ------------------------
  #
  # Both sections appear ONLY at the root help view and ONLY when the
  # user explicitly asked for help (`-h` / `--help` / `help`). Bare
  # `hammer` and namespace listings stay clean. This is project-listing
  # ergonomics: `self:` / Recipes: are tool-meta, not project commands.

  HF ||= "task :x do; desc 'X'; proc { |_| }; end\n" \
         "namespace :gem do; task :build do; desc 'B'; proc { |_| }; end; end\n"

  def test_bare_hammer_hides_self_namespace
    with_hammerfile(HF) do
      out, = capture { Hammer.cli([]) }
      refute_includes out, 'self:'
      refute_includes out, 'self:ai'
    end
  end

  def test_bare_hammer_hides_recipes_section
    with_hammerfile(HF) do
      out, = capture { Hammer.cli([]) }
      refute_includes out, 'Recipes:'
      refute_includes out, 'srt'
    end
  end

  def test_help_flag_shows_self_and_recipes
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['--help']) }
      assert_includes out, 'self:'
      assert_includes out, 'self:ai'
      assert_includes out, 'Recipes:'
      assert_includes out, 'srt'
    end
  end

  def test_short_help_flag_shows_self_and_recipes
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['-h']) }
      assert_includes out, 'self:'
      assert_includes out, 'Recipes:'
    end
  end

  def test_help_word_shows_self_and_recipes
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['help']) }
      assert_includes out, 'self:'
      assert_includes out, 'Recipes:'
    end
  end

  def test_namespace_listing_hides_self_and_recipes
    # `hammer gem:` is a namespace help view, not root - it must not
    # leak the tool-meta sections even though the binary is the hammer
    # one. Same goes for `hammer help gem`.
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['gem:']) }
      refute_includes out, 'self:'
      refute_includes out, 'Recipes:'
      refute_includes out, 'srt'

      out, = capture { Hammer.cli(['help', 'gem']) }
      refute_includes out, 'self:'
      refute_includes out, 'Recipes:'
    end
  end

  def test_user_cli_never_shows_self_or_recipes
    # Subclassing Hammer directly (no @hammer_binary flag) must never
    # surface the tool-meta sections, regardless of --help.
    klass = Class.new(Hammer) do
      task :hello do
        desc 'greet'
        proc { |_| }
      end
    end
    out, = capture { klass.start(['--help']) }
    refute_includes out, 'self:'
    refute_includes out, 'Recipes:'
  end
end
