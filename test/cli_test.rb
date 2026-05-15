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
      define :greet do
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
        define :hi do
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

  def test_missing_hammerfile_exits_1
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        _, err, status = capture_exit { Hammer.cli([]) }
        assert_equal 1, status
        assert_includes err, 'no Hammerfile found'
      end
    end
  end

  def test_namespaces_in_hammerfile
    with_hammerfile(<<~'RUBY') do |_|
      define :build do
        proc { |_| say 'built' }
      end
      namespace :db do
        define :migrate do
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
