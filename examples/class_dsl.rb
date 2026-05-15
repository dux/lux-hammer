#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'lux-hammer'

class MyCli < Hammer
  define :build do
    desc    'Build the project'
    example 'build prod -v'
    example 'build --env=staging'
    opt :verbose, type: :boolean, alias: :v, desc: 'verbose output'
    opt :env,     type: :string,  default: 'dev', desc: 'target env'

    proc do |opts|
      target = opts[:args].first || opts[:env]
      say "building #{target}", :green
      say '  verbose on' if opts[:verbose]
    end
  end

  define :deploy do
    desc    'Deploy to URL'
    example 'deploy https://example.com --force'
    opt :url
    opt :force, type: :boolean, default: false

    proc do |opts|
      raise ArgumentError, 'URL is required' unless opts[:url]
      say "deploying to #{opts[:url]} force=#{opts[:force]}", :yellow
    end
  end

  namespace :db do
    define :migrate do
      desc    'Run pending migrations'
      example 'db:migrate'
      example 'db:migrate 3 --pretend'
      opt :pretend, type: :boolean, alias: :p, desc: 'dry run'

      proc do |opts|
        step = opts[:args].first || 'all'
        say "migrating #{step} pretend=#{opts[:pretend].inspect}", :green
      end
    end

    namespace :users do
      define :list do
        desc 'List users'
        proc { |opts| say "users: #{opts[:args].inspect}", :cyan }
      end
    end
  end
end

MyCli.start(ARGV)
