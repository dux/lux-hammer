require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'

class CliTest < Minitest::Test
  include CaptureIO

  def with_hammerfile(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Hammerfile'), content)
      Dir.chdir(dir) { yield dir }
    end
  end

  def test_finds_hammerfile_in_cwd
    with_hammerfile(<<~'RUBY') do |dir|
      task :greet do
        proc { |opts| say "hi #{opts[:args].first || 'world'}" }
      end
    RUBY
      out, = capture { Hammer.cli(%w[greet dino]) }
      assert_includes out, 'hi dino'
    end
  end

  def test_walks_up_for_hammerfile
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'Hammerfile'), <<~'RUBY')
        task :hi do
          proc { |_| say 'found' }
        end
      RUBY
      nested = File.join(root, 'a', 'b', 'c')
      FileUtils.mkdir_p(nested)
      Dir.chdir(nested) do
        out, = capture { Hammer.cli(['hi']) }
        assert_includes out, 'found'
      end
    end
  end

  def test_missing_hammerfile_with_empty_argv_shows_builtins
    # An empty argv from a dir with no Hammerfile is treated as "the user
    # wants to see what hammer can do" - print help with the self:
    # namespace surfaced (--ai used to live as a flag here).
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli([]) }
        assert_includes out, 'self:ai'
        assert_includes out, 'self:recipe'
      end
    end
  end

  def test_missing_hammerfile_with_user_command_exits_1
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        _, err, status = capture_exit { Hammer.cli(['build']) }
        assert_equal 1, status
        assert_includes err, 'no Hammerfile found'
      end
    end
  end

  def test_self_ai_dumps_agents_md
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli(['self:ai']) }
        assert_includes out, 'AGENTS.md - lux-hammer'
        assert_includes out, 'DSL surface'
      end
    end
  end

  def test_self_ai_works_with_hammerfile_present
    with_hammerfile(<<~'RUBY') do |_|
      task :hi do
        proc { |_| say 'HANDLER_FIRED_UNIQUE_MARKER' }
      end
    RUBY
      out, = capture { Hammer.cli(['self:ai']) }
      assert_includes out, 'AGENTS.md - lux-hammer'
      refute_includes out, 'HANDLER_FIRED_UNIQUE_MARKER'
    end
  end

  def test_namespaces_in_hammerfile
    with_hammerfile(<<~'RUBY') do |_|
      task :build do
        proc { |_| say 'built' }
      end
      namespace :db do
        task :migrate do
          proc { |_| say 'migrated' }
        end
      end
    RUBY
      out1, = capture { Hammer.cli(['build']) }
      out2, = capture { Hammer.cli(['db:migrate']) }
      assert_includes out1, 'built'
      assert_includes out2, 'migrated'
    end
  end
end
