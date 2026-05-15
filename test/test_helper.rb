$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'stringio'
require 'lux-hammer'

# Silence colors and capture stdout/stderr in tests
Hammer::Shell.color!(false)

module CaptureIO
  def capture
    out_was, err_was = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = out_was, err_was
  end

  # Returns [stdout, stderr, exit_status]. exit_status is nil if no exit.
  def capture_exit
    out_was, err_was = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    status = nil
    begin
      yield
    rescue SystemExit => e
      status = e.status
    end
    [$stdout.string, $stderr.string, status]
  ensure
    $stdout, $stderr = out_was, err_was
  end
end
