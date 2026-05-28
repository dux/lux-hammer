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

  def test_no_warning_when_overriding_task_from_outside_app
    cli = Class.new(Hammer)
    # Simulate a task that came from outside the app (an absolute path not
    # under cwd), e.g. a framework default loaded before the app's tasks.
    external = Hammer::Command.new(name: 'foo')
    external.location = '/opt/framework/cli/foo_hammer.rb:1'
    cli.commands['foo'] = external

    _out, err = capture do
      cli.task(:foo) { desc 'app override'; proc {} }
    end
    refute_includes err, 'redefined'
    # Silent override still replaces and is not tagged `(redefined)` in help.
    assert_nil cli.commands['foo'].prev_location
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

  def test_namespace_reopen_merges_without_warning
    cli = nil
    _out, err = capture do
      cli = Class.new(Hammer) do
        namespace :db do
          task(:migrate) { desc 'migrate'; proc {} }
        end
        namespace :db do
          task(:seed) { desc 'seed'; proc {} }
        end
      end
    end
    refute_includes err, 'redefined namespace'
    # Both tasks live on the one merged namespace subclass.
    assert_equal %w[migrate seed], cli.namespaces['db'].commands.keys.sort
  end

  def test_namespace_reopen_runs_tasks_from_both_blocks
    log = []
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        namespace :db do
          task(:migrate) { desc 'migrate'; proc { log << :migrate } }
        end
        namespace :db do
          task(:seed) { desc 'seed'; proc { log << :seed } }
        end
      end
    end
    capture { cli.start(%w[db:migrate]) }
    capture { cli.start(%w[db:seed]) }
    assert_equal %i[migrate seed], log
  end

  def test_namespace_reopen_with_duplicate_task_warns_on_task
    _out, err = capture do
      Class.new(Hammer) do
        namespace :db do
          task(:migrate) { desc 'v1'; proc {} }
        end
        namespace :db do
          task(:migrate) { desc 'v2'; proc {} }
        end
      end
    end
    assert_includes err, '[hammer] redefined task :migrate'
    refute_includes err, 'redefined namespace'
  end

  def test_namespace_reopen_duplicate_task_last_wins
    log = []
    cli = nil
    capture do
      cli = Class.new(Hammer) do
        namespace :db do
          task(:migrate) { desc 'v1'; proc { log << :v1 } }
        end
        namespace :db do
          task(:migrate) { desc 'v2'; proc { log << :v2 } }
        end
      end
    end
    capture { cli.start(%w[db:migrate]) }
    assert_equal [:v2], log
  end

  def test_nested_namespace_reopen_merges
    cli = nil
    _out, err = capture do
      cli = Class.new(Hammer) do
        namespace :db do
          namespace :users do
            task(:list) { desc 'list'; proc {} }
          end
        end
        namespace :db do
          namespace :users do
            task(:add) { desc 'add'; proc {} }
          end
        end
      end
    end
    refute_includes err, 'redefined namespace'
    assert_equal %w[add list], cli.namespaces['db'].namespaces['users'].commands.keys.sort
  end
end
