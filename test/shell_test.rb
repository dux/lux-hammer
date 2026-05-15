require_relative 'test_helper'

class ShellTest < Minitest::Test
  include CaptureIO

  def setup
    Hammer::Shell.color!(false)
  end

  def test_say_prints_with_newline
    out, = capture { Hammer::Shell.say('hi') }
    assert_equal "hi\n", out
  end

  def test_error_raises_hammer_error
    err = assert_raises(Hammer::Error) { Hammer::Shell.error('boom') }
    assert_equal 'boom', err.message
  end

  def test_print_error_writes_to_stderr_without_exiting
    _, err = capture { Hammer::Shell.print_error('boom') }
    assert_includes err, 'boom'
    assert_includes err, '[error]'
  end

  def test_color_off_returns_plain
    assert_equal 'x', Hammer::Shell.paint('x', :red)
  end

  def test_color_on_wraps_ansi
    Hammer::Shell.color!(true)
    painted = Hammer::Shell.paint('x', :red)
    assert_includes painted, "\e[31m"
    assert_includes painted, "\e[0m"
  ensure
    Hammer::Shell.color!(false)
  end

  def test_ask_returns_default_on_blank_input
    $stdin = StringIO.new("\n")
    out, = capture { @result = Hammer::Shell.ask('name', default: 'world') }
    assert_equal 'world', @result
    assert_includes out, 'name'
  ensure
    $stdin = STDIN
  end

  def test_ask_returns_input
    $stdin = StringIO.new("dino\n")
    capture { @result = Hammer::Shell.ask('name') }
    assert_equal 'dino', @result
  ensure
    $stdin = STDIN
  end

  def test_yes_true_on_y
    $stdin = StringIO.new("y\n")
    capture { @result = Hammer::Shell.yes?('go?') }
    assert_equal true, @result
  ensure
    $stdin = STDIN
  end

  def test_yes_false_on_blank
    $stdin = StringIO.new("\n")
    capture { @result = Hammer::Shell.yes?('go?') }
    assert_equal false, @result
  ensure
    $stdin = STDIN
  end

  def test_sh_runs_command_and_echoes
    out, = capture { Hammer::Shell.sh('true') }
    assert_includes out, '$ true'
  end

  def test_sh_raises_on_nonzero_exit
    err = assert_raises(Hammer::Error) do
      capture { Hammer::Shell.sh('false') }
    end
    assert_includes err.message, 'command failed: false'
  end
end
