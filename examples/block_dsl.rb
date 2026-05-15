#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'lux-hammer'

Hammer.run(ARGV) do
  define :hello do
    desc    'Greet someone'
    example 'hello'
    example 'hello dino -l'
    opt :loud, type: :boolean, alias: :l

    proc do |opts|
      msg = "hello #{opts[:args].first || 'world'}"
      msg = msg.upcase if opts[:loud]
      say msg, :cyan
    end
  end
end
