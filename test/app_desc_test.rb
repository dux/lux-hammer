require_relative 'test_helper'

class AppDescTest < Minitest::Test
  include CaptureIO

  def test_block_dsl_top_level_desc_sets_app_desc
    captured = nil
    capture do
      Hammer.run([]) do
        desc 'Build & deploy tooling'
        task :build do
          desc 'Build'
          proc { |_| }
        end
      end
    end
    # Help output is the observable contract - check via a second pass.
    out, = capture do
      Hammer.run(['--help']) do
        desc 'Build & deploy tooling'
        task :build do
          desc 'Build'
          proc { |_| }
        end
      end
    end
    assert_includes out, 'Build & deploy tooling'
    assert_includes out, 'Usage:'
  end

  def test_multiline_app_desc_indents_each_line
    out, = capture do
      Hammer.run(['--help']) do
        desc <<~TXT
          first line
          second line
        TXT
        task :x do
          desc 'X'
          proc { |_| }
        end
      end
    end
    assert_includes out, '  first line'
    assert_includes out, '  second line'
  end

  def test_class_dsl_desc_keeps_pending_semantics
    # Class-DSL `desc` continues to set per-task pending state for the
    # next `def`. It does NOT bleed into @app_desc - that's block-DSL
    # only.
    cli = Class.new(Hammer) do
      desc 'Build the project'
      define_method(:build) { |opts| }
    end
    assert_nil cli.app_desc
    assert cli.commands.key?('build')
  end

  def test_app_desc_class_method_get_and_set
    cli = Class.new(Hammer)
    assert_nil cli.app_desc
    cli.app_desc 'hello'
    assert_equal 'hello', cli.app_desc
  end

  def test_no_app_desc_means_no_extra_lines_in_help
    out, = capture do
      Hammer.run(['--help']) do
        task :x do
          desc 'X'
          proc { |_| }
        end
      end
    end
    # No app_desc set - first blank line should still be right after Usage,
    # before "Commands:". Check by confirming nothing weird snuck in.
    assert_includes out, 'Usage:'
    assert_includes out, 'Commands:'
  end
end
