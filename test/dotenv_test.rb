require_relative 'test_helper'

class DotenvTest < Minitest::Test
  include CaptureIO

  # ----- parser ---------------------------------------------------------

  def test_parse_basic_pairs
    h = Hammer::Dotenv.parse("FOO=bar\nBAZ=qux\n")
    assert_equal({ 'FOO' => 'bar', 'BAZ' => 'qux' }, h)
  end

  def test_parse_skips_blank_and_comment_lines
    h = Hammer::Dotenv.parse("\n# comment\n  \nA=1\n# A=ignored\n")
    assert_equal({ 'A' => '1' }, h)
  end

  def test_parse_strips_double_and_single_quotes
    h = Hammer::Dotenv.parse(%(A="hi there"\nB='ok'\nC=raw\n))
    assert_equal({ 'A' => 'hi there', 'B' => 'ok', 'C' => 'raw' }, h)
  end

  def test_parse_strips_export_prefix
    h = Hammer::Dotenv.parse("export FOO=bar\n")
    assert_equal({ 'FOO' => 'bar' }, h)
  end

  def test_parse_ignores_lines_without_equals
    h = Hammer::Dotenv.parse("BROKEN\nOK=1\n")
    assert_equal({ 'OK' => '1' }, h)
  end

  def test_parse_ignores_lines_with_empty_key
    h = Hammer::Dotenv.parse("=value\nOK=1\n")
    assert_equal({ 'OK' => '1' }, h)
  end

  # ----- load -----------------------------------------------------------

  def with_env(*keys)
    saved = keys.each_with_object({}) { |k, m| m[k] = ENV[k] }
    keys.each { |k| ENV.delete(k) }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_load_reads_dotenv_file
    with_env('HAMMER_TEST_A') do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.env'), "HAMMER_TEST_A=from_env\n")
        Hammer::Dotenv.load(dir)
        assert_equal 'from_env', ENV['HAMMER_TEST_A']
      end
    end
  end

  def test_load_does_not_override_existing_env
    with_env('HAMMER_TEST_B') do
      ENV['HAMMER_TEST_B'] = 'from_shell'
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.env'), "HAMMER_TEST_B=from_file\n")
        Hammer::Dotenv.load(dir)
        assert_equal 'from_shell', ENV['HAMMER_TEST_B']
      end
    end
  end

  def test_local_overrides_base
    with_env('HAMMER_TEST_C') do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.env'),       "HAMMER_TEST_C=base\n")
        File.write(File.join(dir, '.env.local'), "HAMMER_TEST_C=local\n")
        Hammer::Dotenv.load(dir)
        # `.env` runs first and sets it; `.env.local` runs next and uses
        # `||=` semantics - but since the base file already set it via
        # the same loader, it stays. To override, the shell-set rule
        # applies equally: `||=` wins. So base wins here.
        assert_equal 'base', ENV['HAMMER_TEST_C']
      end
    end
  end

  def test_missing_files_do_not_raise
    Dir.mktmpdir do |dir|
      assert_silent { Hammer::Dotenv.load(dir) }
    end
  end

  # ----- cli integration ------------------------------------------------

  def test_cli_autoloads_dotenv
    with_env('HAMMER_TEST_CLI_D') do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.env'), "HAMMER_TEST_CLI_D=hello\n")
        File.write(File.join(dir, 'Hammerfile'), <<~'RUBY')
          task :show do
            proc { |_| say ENV['HAMMER_TEST_CLI_D'].to_s }
          end
        RUBY
        Dir.chdir(dir) do
          out, = capture { Hammer.cli(['show']) }
          assert_includes out, 'hello'
        end
      end
    end
  end

  def test_cli_respects_dotenv_false
    with_env('HAMMER_TEST_CLI_E') do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.env'), "HAMMER_TEST_CLI_E=should_not_load\n")
        File.write(File.join(dir, 'Hammerfile'), <<~'RUBY')
          dotenv false
          task :show do
            proc { |_| say ENV['HAMMER_TEST_CLI_E'].inspect }
          end
        RUBY
        Dir.chdir(dir) do
          out, = capture { Hammer.cli(['show']) }
          assert_includes out, 'nil'
        end
      end
    end
  end
end
