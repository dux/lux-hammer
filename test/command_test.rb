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

  def test_finalize_auto_assigns_first_letter_short_alias
    c = Hammer::Command.new(name: 'gem')
    c.add_option(Hammer::Option.new(:build,   type: :boolean))
    c.add_option(Hammer::Option.new(:publish, type: :boolean))
    c.finalize!
    assert_equal ['-b'], c.options[0].aliases
    assert_equal ['-p'], c.options[1].aliases
  end

  def test_finalize_skips_when_letter_already_claimed_by_explicit_alias
    c = Hammer::Command.new(name: 'gem')
    # build claims -b explicitly; bump would want -b too, must be skipped.
    c.add_option(Hammer::Option.new(:bump))
    c.add_option(Hammer::Option.new(:build, type: :boolean, alias: :b))
    c.finalize!
    assert_empty c.options[0].aliases
    assert_equal ['-b'], c.options[1].aliases
  end

  def test_finalize_skips_when_two_opts_share_first_letter
    c = Hammer::Command.new(name: 'x')
    c.add_option(Hammer::Option.new(:build, type: :boolean))
    c.add_option(Hammer::Option.new(:bump))
    c.finalize!
    # build wins (declared first); bump gets nothing rather than a
    # surprise second-letter pick.
    assert_equal ['-b'], c.options[0].aliases
    assert_empty c.options[1].aliases
  end

  def test_finalize_does_not_claim_dash_h
    c = Hammer::Command.new(name: 'x')
    c.add_option(Hammer::Option.new(:help_text))
    c.finalize!
    assert_empty c.options[0].aliases
  end

  def test_finalize_leaves_existing_short_alias_untouched
    c = Hammer::Command.new(name: 'x')
    c.add_option(Hammer::Option.new(:verbose, type: :boolean, alias: :V))
    c.finalize!
    assert_equal ['-V'], c.options[0].aliases
  end

  def test_finalize_still_assigns_short_when_only_long_alias_present
    c = Hammer::Command.new(name: 'x')
    c.add_option(Hammer::Option.new(:rollback, alias: :back))
    c.finalize!
    assert_equal ['--back', '-r'], c.options[0].aliases
  end

  def test_finalize_is_idempotent
    c = Hammer::Command.new(name: 'x')
    c.add_option(Hammer::Option.new(:env))
    c.finalize!
    c.finalize!
    assert_equal ['-e'], c.options[0].aliases
  end
end
