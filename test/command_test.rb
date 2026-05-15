require_relative 'test_helper'

class CommandTest < Minitest::Test
  def test_defaults
    c = Hammer::Command.new(name: 'build')
    assert_equal 'build', c.name
    assert_equal '',      c.desc
    assert_empty c.options
    assert_empty c.examples
    assert_empty c.alts
  end

  def test_matches_canonical_name
    c = Hammer::Command.new(name: 'server')
    assert c.matches?('server')
    refute c.matches?('s')
  end

  def test_matches_alt
    c = Hammer::Command.new(name: 'server')
    c.add_alt(:s)
    c.add_alt('srv')
    assert c.matches?('s')
    assert c.matches?(:srv)
    refute c.matches?('nope')
  end

  def test_add_option_and_example
    c = Hammer::Command.new(name: 'x')
    c.add_option(Hammer::Option.new(:env))
    c.add_example('x foo')
    assert_equal 1, c.options.size
    assert_equal ['x foo'], c.examples
  end
end
