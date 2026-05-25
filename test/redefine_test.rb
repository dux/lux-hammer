require_relative 'test_helper'

class RedefineTest < Minitest::Test
  include CaptureIO

  # ----- task ---------------------------------------------------------

  def test_task_redefinition_warns_on_stderr
    _out, err = capture do
      Class.new(Hammer) do
        task(:foo) { desc 'first';  proc {} }
        task(:foo) { desc 'second'; proc {} }
      end
    end
    assert_includes err, '[hammer] redefined task :foo'
    assert_match(/redefine_test\.rb:\d+/, err)
  end

  def test_redefined_task_dispatches_to_latest
    log = []
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        desc 'first'
        task(:foo) { desc 'first';  proc { log << :first } }
        task(:foo) { desc 'second'; proc { log << :second } }
      end
    end
    capture { cli.start(%w[foo]) }
    assert_equal [:second], log
  end

  def test_help_marks_redefined_command
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        task(:foo) { desc 'first';  proc {} }
        task(:foo) { desc 'second'; proc {} }
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, '(redefined)'
  end

  def test_locations_captured
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        task(:foo) { desc 'first';  proc {} }
        task(:foo) { desc 'second'; proc {} }
      end
    end
    cmd = cli.commands['foo']
    refute_nil cmd.location
    refute_nil cmd.prev_location
    assert_match(/redefine_test\.rb:\d+/, cmd.location)
    assert_match(/redefine_test\.rb:\d+/, cmd.prev_location)
    refute_equal cmd.location, cmd.prev_location
  end

  def test_no_warning_when_unique
    _out, err = capture do
      Class.new(Hammer) do
        desc 'only'
        task(:foo) { proc {} }
      end
    end
    refute_includes err, 'redefined'
  end

  def test_unique_task_has_no_prev_location
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        desc 'only'
        task(:foo) { proc {} }
      end
    end
    assert_nil cli.commands['foo'].prev_location
  end

  def test_help_does_not_mark_unique_command
    cli = Class.new(Hammer) do
      desc 'only'
      task(:foo) { proc {} }
    end
    out, = capture { cli.start(['help']) }
    refute_includes out, '(redefined)'
  end

  # ----- namespace ----------------------------------------------------

  def test_namespace_redefinition_warns
    _out, err = capture do
      Class.new(Hammer) do
        namespace :db do
          desc 'migrate v1'
          task(:migrate) { proc {} }
        end
        namespace :db do
          desc 'migrate v2'
          task(:migrate) { proc {} }
        end
      end
    end
    assert_includes err, '[hammer] redefined namespace :db'
  end

  def test_namespace_redefinition_last_wins
    log = []
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        namespace :db do
          desc 'migrate v1'
          task(:migrate) { proc { log << :v1 } }
        end
        namespace :db do
          desc 'migrate v2'
          task(:migrate) { proc { log << :v2 } }
        end
      end
    end
    capture { cli.start(%w[db:migrate]) }
    assert_equal [:v2], log
  end
end
