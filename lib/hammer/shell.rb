class Hammer
  # ANSI color/output helpers. Mixed into command instances; also callable
  # directly as `Hammer::Shell.say(...)`.
  module Shell
    COLORS ||= {
      black:   30, red:     31, green:   32, yellow:  33,
      blue:    34, magenta: 35, cyan:    36, white:   37,
      gray:    90
    }.freeze

    module_function

    def color?
      return @color if defined?(@color)
      @color = $stdout.tty? && ENV['NO_COLOR'].nil?
    end

    def color!(value)
      @color = value
    end

    def paint(text, color = nil, bold: false)
      return text.to_s unless color? && (color || bold)
      code = COLORS[color] || 0
      prefix = bold ? "\e[1;#{code}m" : "\e[#{code}m"
      "#{prefix}#{text}\e[0m"
    end

    def say(text = '', color = nil, bold: false)
      puts paint(text, color, bold: bold)
    end

    # Raise a controlled Hammer::Error. If unhandled, the dispatcher
    # prints the message in red and exits 1 - no backtrace, no help spam.
    #
    #   error 'config file missing' unless File.exist?(path)
    def error(text)
      raise Hammer::Error, text
    end

    # Print a red [error] line to stderr (does not exit). Used internally
    # by the dispatcher to render Hammer::Error messages.
    def print_error(text)
      warn paint("[error] #{text}", :red, bold: true)
    end

    def ask(prompt, default: nil)
      suffix = default ? " [#{default}]" : ''
      print paint("#{prompt}#{suffix}: ", :cyan)
      line = $stdin.gets
      return default if line.nil?
      line = line.chomp
      line.empty? ? default : line
    end

    def yes?(prompt)
      answer = ask("#{prompt} (y/N)")
      return false if answer.nil?
      answer.to_s.strip.downcase.start_with?('y')
    end

    # Run a shell command. Echoes the command in gray, raises
    # Hammer::Error on non-zero exit. Returns true on success.
    def sh(cmd)
      say "$ #{cmd}", :gray
      error "command failed: #{cmd}" unless system(cmd)
      true
    end
  end
end
