require_relative 'test_helper'

class ParserTest < Minitest::Test
  def parse(opts, argv)
    Hammer::Parser.new(opts).parse(argv)
  end

  def test_empty_argv_empty_options
    pos, opts = parse([], [])
    assert_equal [], pos
    assert_equal({}, opts)
  end

  def test_collects_positional
    pos, opts = parse([], %w[a b c])
    assert_equal %w[a b c], pos
    assert_equal({}, opts)
  end

  def test_string_option_with_equals
    o = Hammer::Option.new(:env, type: :string)
    pos, opts = parse([o], %w[--env=prod])
    assert_equal [], pos
    assert_equal 'prod', opts[:env]
  end

  def test_string_option_with_space
    o = Hammer::Option.new(:env, type: :string)
    _, opts = parse([o], %w[--env prod])
    assert_equal 'prod', opts[:env]
  end

  def test_boolean_via_long_flag
    o = Hammer::Option.new(:verbose, type: :boolean)
    _, opts = parse([o], %w[--verbose])
    assert_equal true, opts[:verbose]
  end

  def test_boolean_via_negation
    o = Hammer::Option.new(:cache, type: :boolean, default: true)
    _, opts = parse([o], %w[--no-cache])
    assert_equal false, opts[:cache]
  end

  def test_boolean_via_short_alias
    o = Hammer::Option.new(:verbose, type: :boolean, alias: :v)
    _, opts = parse([o], %w[-v])
    assert_equal true, opts[:verbose]
  end

  def test_default_when_omitted
    o = Hammer::Option.new(:env, type: :string, default: 'dev')
    _, opts = parse([o], [])
    assert_equal 'dev', opts[:env]
  end

  def test_integer_casting
    o = Hammer::Option.new(:port, type: :integer)
    _, opts = parse([o], %w[--port 8080])
    assert_equal 8080, opts[:port]
  end

  def test_array_casting
    o = Hammer::Option.new(:tags, type: :array)
    _, opts = parse([o], %w[--tags a,b,c])
    assert_equal %w[a b c], opts[:tags]
  end

  def test_double_dash_stops_parsing
    o = Hammer::Option.new(:env, type: :string)
    pos, opts = parse([o], %w[--env prod -- --not-a-flag x])
    assert_equal %w[--not-a-flag x], pos
    assert_equal 'prod', opts[:env]
  end

  def test_mixed_positional_and_flags
    o = Hammer::Option.new(:env, type: :string)
    pos, opts = parse([o], %w[deploy https://x.com --env=prod])
    assert_equal %w[deploy https://x.com], pos
    assert_equal 'prod', opts[:env]
  end

  def test_unknown_option_raises
    assert_raises(Hammer::Parser::Error) { parse([], %w[--nope]) }
    assert_raises(Hammer::Parser::Error) { parse([], %w[-x]) }
  end

  def test_missing_value_raises
    o = Hammer::Option.new(:env, type: :string)
    assert_raises(Hammer::Parser::Error) { parse([o], %w[--env]) }
  end

  def test_required_missing_raises
    o = Hammer::Option.new(:env, type: :string, req: true)
    assert_raises(Hammer::Parser::Error) { parse([o], []) }
  end

  def test_positional_fills_opts_in_declaration_order
    url = Hammer::Option.new(:url)
    env = Hammer::Option.new(:env)
    pos, opts = parse([url, env], %w[https://x.com prod])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    assert_equal 'prod', opts[:env]
  end

  def test_positional_overflow_goes_to_args
    url = Hammer::Option.new(:url)
    pos, opts = parse([url], %w[https://x.com extra1 extra2])
    assert_equal %w[extra1 extra2], pos
    assert_equal 'https://x.com', opts[:url]
  end

  def test_positional_skips_booleans
    verbose = Hammer::Option.new(:verbose, type: :boolean)
    url     = Hammer::Option.new(:url)
    pos, opts = parse([verbose, url], %w[https://x.com])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    refute opts.key?(:verbose)
  end

  def test_flag_value_wins_over_positional
    url = Hammer::Option.new(:url)
    env = Hammer::Option.new(:env)
    pos, opts = parse([url, env], %w[--env prod https://x.com])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    assert_equal 'prod', opts[:env]
  end

  def test_positional_is_cast_to_opt_type
    port = Hammer::Option.new(:port, type: :integer)
    _, opts = parse([port], %w[8080])
    assert_equal 8080, opts[:port]
  end

  def test_positional_satisfies_required
    url = Hammer::Option.new(:url, req: true)
    _, opts = parse([url], %w[https://x.com])
    assert_equal 'https://x.com', opts[:url]
  end
end
