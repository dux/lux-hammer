# hammer

A modern CLI builder for Ruby. The good parts of
[Rake](https://github.com/ruby/rake) and
[Thor](https://github.com/rails/thor) without the cruft. Drop a
`Hammerfile`, run `hammer`, ship.

## Install

```ruby
gem 'lux-hammer'
```

Or from the command line:

```sh
gem install lux-hammer
```

This installs the `hammer` binary and exposes `require 'lux-hammer'`.

## Quick start

Create a `Hammerfile` in your project root:

```ruby
define :hello do
  desc 'say hi'
  proc do |opts|
    say "hello #{opts[:args].first || 'world'}", :green
  end
end
```

Then:

```sh
$ hammer hello
hello world
$ hammer hello dino
hello dino
$ hammer
Usage: hammer COMMAND [ARGS]

Commands:
  hammer hello  # say hi
```

That's it. `hammer` walks up from your current directory looking for a
`Hammerfile`, evaluates it, and dispatches.

## Why hammer (the short pitch)

A handful of papercuts from Rake and Thor that hammer just doesn't have.

### Rake task arguments are awkward

Rake forces you into `task[arg1,arg2]` syntax with no types, no flags,
no help, and shell-hostile brackets:

```ruby
# Rakefile
task :greet, [:name, :loud] do |_, args|
  puts args[:loud] == 'true' ? "HELLO #{args[:name].upcase}" : "hello #{args[:name]}"
end
```
```sh
$ rake 'greet[dino,true]'    # quotes required - zsh/bash treat [] as globs
```

Hammer takes typed options, positional fill, and any common flag form:

```ruby
# Hammerfile
define :greet do
  desc 'Say hello'
  opt :name
  opt :loud, type: :boolean, alias: :l
  proc { |o| say o[:loud] ? "HELLO #{o[:name].upcase}" : "hello #{o[:name]}" }
end
```
```sh
$ hammer greet dino -l              # positional fills :name, -l sets :loud
$ hammer greet --name=dino --loud   # or be explicit
$ hammer greet -h                   # real help, with defaults and examples
```

### Invoking another task

```ruby
# Rake
Rake::Task['db:migrate'].invoke('prod')
```
```ruby
# hammer - reads like a normal Ruby method call
hammer_db_migrate(env: 'prod')
```

### Thor: `desc` welded to a method, no aliases, two arg systems

Thor splits arguments between method parameters and `method_option`,
needs a usage string repeated in `desc`, and has no first-class command
aliases (you reach for `map`):

```ruby
# Thor
class MyCli < Thor
  desc 'greet NAME', 'Say hello'              # usage repeated by hand
  method_option :loud, type: :boolean, aliases: '-l'
  def greet(name)                             # name is a method param...
    options[:loud] ? puts(name.upcase) : puts(name)   # ...options live elsewhere
  end
  map 'g' => :greet                           # aliases bolted on
end
```

```ruby
# hammer - one arg system, real aliases, no usage string to maintain
define :greet do
  desc 'Say hello'
  alt :g
  opt :name
  opt :loud, type: :boolean, alias: :l
  proc { |o| say o[:loud] ? o[:name].upcase : o[:name] }
end
```

Usage is generated from your `opt`s, `alt :g` registers a real alias,
and there's one place to look for everything the command takes.

## The two styles

### `define :name do ... end` (block DSL)

The block's **last expression must be `proc do |opts| ... end`**. That
proc is the handler. Everything before it is metadata.

```ruby
define :build do
  desc    'Build the project'
  example 'build prod -v'
  opt :verbose, type: :boolean, alias: :v
  opt :env,     default: 'dev'

  proc do |opts|
    say "building #{opts[:env]}", :green
  end
end
```

### `desc` + `def` (classic DSL)

For when you'd rather write a Ruby method:

```ruby
class MyCli < Hammer
  program_name 'mycli'

  desc 'Build the project'
  opt :verbose, type: :boolean, alias: :v
  opt :env,     default: 'dev'
  def build(opts)
    say "building #{opts[:env]}", :green
  end

  desc 'Ping with no opts'
  def ping
    say 'pong'
  end
end

MyCli.start(ARGV)
```

`desc` is the trigger - a `def` without a preceding `desc` is just a
regular method, never a command. Methods with arity 0 are called
without opts; methods that take an argument receive the opts hash.

Both styles can coexist in the same class.

## Program name

`program_name 'foo'` (alias `program 'foo'`) sets the name shown in
help/usage output. It is **optional**. When omitted, the default is:

* the invocation path **relative to cwd** if the script lives inside
  the current working directory (e.g. `bin/foo` when invoked from the
  project root as `./bin/foo` or `bin/foo`), or
* the **basename** of `$PROGRAM_NAME` otherwise (e.g. `lux` for a
  globally installed bin in `PATH`).

So a project-local wrapper at `bin/foo` shows up in help as
`Usage: bin/foo COMMAND [ARGS]`, while the same library invoked
through a globally installed `lux` shim shows `Usage: lux ...`. Set
`program 'whatever'` explicitly to override.

## Options (`opt`)

### Declaration

```ruby
opt :name,
    type:     :string,    # :string (default) :boolean :integer :float :array
    default:  nil,        # default value when omitted
    alias:    :n,         # one or many - see below
    desc:     'help text',# shown in `help COMMAND`
    req:      false       # raise at parse time if not supplied
```

Underscores in the name become dashes in the flag:
`opt :dry_run` → `--dry-run`. The kwarg key in `opts` is still
`:dry_run`.

### Invocation forms

For value options (anything that's not `:boolean`), all three forms work:

```
--port=3000        # long with equals
--port 3000        # long with space
-p 3000            # short alias with space  (requires alias: :p)
```

Not supported: attached short form (`-p3000`), combined short flags
(`-vf`).

For boolean options:

```
--verbose          # set to true
--no-verbose       # set to false (only if a default of true is in play)
-v                 # short alias if declared
```

### Per-type behavior

#### `:string` (default)

```ruby
opt :env, default: 'dev'
```
```
hammer build --env prod         # opts[:env] = "prod"
hammer build --env=prod         # opts[:env] = "prod"
hammer build                    # opts[:env] = "dev"  (default)
```

#### `:boolean`

```ruby
opt :verbose, type: :boolean, alias: :v
opt :cache,   type: :boolean, default: true
```
```
hammer build -v                 # opts[:verbose] = true
hammer build --verbose          # opts[:verbose] = true
hammer build --no-cache         # opts[:cache]   = false  (negates default)
hammer build                    # opts[:cache]   = true   (default)
                                # opts[:verbose] = nil    (no default)
```

Booleans never consume a positional. `--no-X` only meaningfully overrides
a `default: true`.

#### `:integer`

```ruby
opt :port, type: :integer, default: 3000, alias: :p
```
```
hammer serve --port 8080        # opts[:port] = 8080
hammer serve -p 8080            # opts[:port] = 8080
hammer serve                    # opts[:port] = 3000
```

Bad input raises a parse error: `--port=abc` → `invalid value for Integer()`.

#### `:float`

```ruby
opt :threshold, type: :float, default: 0.5
```
```
hammer scan --threshold 0.95    # opts[:threshold] = 0.95
```

#### `:array`

Comma-separated. No surrounding whitespace.

```ruby
opt :tags, type: :array, default: []
```
```
hammer deploy --tags a,b,c      # opts[:tags] = ["a", "b", "c"]
hammer deploy --tags=foo        # opts[:tags] = ["foo"]
hammer deploy                   # opts[:tags] = []
```

### Aliases (`alias:`)

A symbol becomes a flag automatically (1 char -> short, more -> long).
Strings starting with `-` pass through. One value or an array:

```ruby
opt :port,     alias: :p                   # -> -p
opt :pretend,  alias: :p                   # -> -p
opt :rollback, alias: :back                # -> --back  (multi-letter symbol)
opt :verbose,  alias: [:v, :V, :loud]      # -> -v, -V, --loud
opt :env,      alias: '-E'                 # string with `-` passes through
```

### Required

`req: true` raises a parse error if neither a flag nor a positional
fills the opt:

```ruby
opt :url, req: true
```
```
$ hammer deploy
[error] missing required --url
```

A positional satisfies it: `hammer deploy https://x.com` works because
of the declaration-order positional fill (see below).

### Defaults

`default:` is used when neither a flag nor a positional supplies the
value:

```ruby
opt :env, default: 'dev'
```

Note: boolean defaults of `nil` (the implicit default) and `false` are
not the same. `nil` means "not set; key absent from opts unless a flag
appears". Explicit `default: false` means "key always present, value
false unless `--flag` is passed".

### Positional fill (declaration order)

Anything in ARGV without `-` / `--` fills the next un-set
**non-boolean** opt, in declaration order:

```ruby
define :deploy do
  opt :url
  opt :env, default: 'dev'
  proc { |opts| ... }
end
```

These all produce the same `opts`:

```
hammer deploy https://x.com prod        # both positional
hammer deploy https://x.com --env=prod  # mixed
hammer deploy --url=https://x.com prod  # mixed reverse
hammer deploy --url=https://x.com --env=prod  # both flags
```

Rules recap:

* Boolean opts are skipped during positional fill.
* A flag value wins over a positional for the same opt.
* Leftover positionals go to `opts[:args]`.
* A positional satisfying a `req: true` opt counts as supplied.

### The `opts` hash

Always a `Hash` with **symbol keys**. Keys present:

* one per declared option that was supplied (via flag, positional, or
  default)
* `opts[:args]` - array of positional ARGV not absorbed by an opt

```ruby
define :show do
  opt :env, default: 'dev'
  opt :loud, type: :boolean
  proc { |opts| p opts }
end
```
```
$ hammer show foo bar --env=prod --loud
{env: "prod", loud: true, args: ["foo", "bar"]}

$ hammer show
{env: "dev", args: []}
```

### Stopping option parsing (`--`)

A bare `--` ends option parsing; everything after goes to `opts[:args]`
verbatim, even if it looks like a flag:

```
hammer build --env=prod -- --not-a-flag foo
# opts[:env]  = "prod"
# opts[:args] = ["--not-a-flag", "foo"]
```

## Namespaces (Rake-style colon paths)

Commands inside a `namespace :name do ... end` block are reached via
colon-paths from the root binary - just like `rake db:migrate`:

```ruby
namespace :db do
  define :migrate do
    proc { |opts| ... }
  end

  namespace :users do
    define :list do
      proc { |opts| ... }
    end
  end
end
```

Then:

```
hammer db:migrate
hammer db:users:list
hammer db                 # bare namespace lists everything under it
hammer db:migrate -h      # per-command help
```

Namespaces nest to any depth. There is no per-level dispatch - the root
parses the whole colon path and walks the namespace tree.

## Command aliases (`alt`)

`alt :short_name` (or several) registers extra names for a command:

```ruby
define :server do
  alt :s, :srv
  proc { |opts| ... }
end
```

Then `hammer server`, `hammer s`, and `hammer srv` all dispatch to the
same command. Alts work inside namespaces too: `alt :m` on `db:migrate`
makes `db:m` resolve.

## Cross-invocation (`hammer_*`)

From inside any command's proc - or from outside via the class - you can
invoke other commands without re-shelling out:

```ruby
define :deploy do
  proc do |opts|
    hammer_build(env: 'prod', verbose: true)
    hammer_db_migrate
    say 'deployed', :green
  end
end
```

The mapping mirrors the CLI literally:

* `hammer_X_Y_Z` → command path `X:Y:Z` (underscores in the method
  name become colons)
* positional args → positional ARGV
* `verbose: true` → `--verbose`
* `no_cache: true` → `--no-cache` (just the same rule - underscores in
  the kwarg key become dashes)
* `dry_run: true` → `--dry-run`
* `env: 'prod'` → `--env=prod`
* `anything: false` → skipped (no-op; use `no_x: true` to negate)

`MyCli.hammer_db_users_list("a", verbose: true)` also works at the
class level, useful for tests and scripting.

## Shell helpers

Available inside any handler:

```ruby
say 'ok', :green
say 'big', :yellow, bold: true
error 'something broke'        # prints + exits 1 (raises Hammer::Error)
name = ask 'name', default: 'world'
exit 0 unless yes? 'continue?'
sh 'bundle install'            # echoes "$ bundle install", aborts on non-zero
```

Colors are auto-disabled when stdout isn't a TTY, when `NO_COLOR` is
set, or programmatically via `Hammer::Shell.color!(false)`.

## Splitting across files (`load`)

Once a `Hammerfile` grows past a screen or two, split it. Drop fragments
in any file ending in `_hammer.rb` and pull them in with `load`:

```ruby
# Hammerfile
program 'demo'
load auto: true              # recursive scan for *_hammer.rb from here
```

```ruby
# tasks/db_hammer.rb
namespace :db do
  define :migrate do
    desc 'Run pending migrations'
    opt :pretend, type: :boolean, alias: :p
    proc { |o| say "migrating pretend=#{o[:pretend].inspect}", :green }
  end
end
```

```ruby
# tasks/deploy_hammer.rb
define :deploy do
  desc 'Deploy to prod'
  proc do |_|
    hammer_db_migrate        # cross-file invocation just works
    say 'deployed', :cyan
  end
end
```

### Call shapes

```ruby
load                         # same as load auto: true
load auto: true              # recursive scan for *_hammer.rb under caller dir
load 'tasks/db_hammer.rb'    # one file (path relative to caller)
load 'tasks/*_hammer.rb'     # glob
load 'a.rb', 'b.rb'          # several explicit paths
```

Paths resolve relative to the file calling `load`, not cwd. Inside a
`Hammerfile` that means "relative to the Hammerfile"; inside a class
body it means "relative to that file".

### What's skipped

Auto-discovery walks recursively but skips `.git`, `.bundle`,
`node_modules`, `tmp`, `vendor`, `dist`, `build`, `coverage`, and any
hidden directory.

### Fragment shape

A `*_hammer.rb` file is a **block-DSL fragment** - same surface as a
`Hammerfile`: `define`, `namespace`, and nested `load`. Not a class
re-open. If you want to extend a `Hammer` subclass in the classic
`desc` + `def` style across files, use plain `require_relative`.

### Dedup and re-entrancy

Each file loads at most once per target class, keyed by absolute path.
A fragment can `load` other fragments without worrying about cycles.

### Errors

If a fragment raises during load, the error surfaces as
`failed loading <path>: <message>` so you know which file blew up.
An explicit pattern (`load 'x_hammer.rb'`, `load 'tasks/*.rb'`) that
matches zero files raises; auto-mode finding nothing is silent.

## Block DSL outside a Hammerfile

Same shape as a Hammerfile, just inline:

```ruby
require 'lux-hammer'

Hammer.run(ARGV) do
  program 'inline'

  define :hello do
    desc 'say hi'
    opt :loud, type: :boolean, alias: :l
    proc do |opts|
      msg = "hello #{opts[:args].first || 'world'}"
      msg = msg.upcase if opts[:loud]
      say msg, :cyan
    end
  end
end
```

## Complete example (every feature)

```ruby
# Hammerfile
program 'demo'

# Simple top-level command
define :build do
  desc    'Build the project'
  example 'build prod -v'
  example 'build --env=staging'
  opt :verbose, type: :boolean, alias: :v, desc: 'verbose output'
  opt :env,     default: 'dev', desc: 'target env'

  proc do |opts|
    target = opts[:args].first || opts[:env]
    say "building #{target}", :green, bold: true
    say '  verbose on' if opts[:verbose]
  end
end

# Command that calls another command
define :deploy do
  desc 'Deploy to URL'
  alt :ship
  opt :url, req: true
  opt :force, type: :boolean

  proc do |opts|
    hammer_build(env: 'prod')
    exit 0 unless yes? "deploy to #{opts[:url]}?" unless opts[:force]
    say "deploying to #{opts[:url]}", :yellow
  end
end

# Namespace with two levels of nesting
namespace :db do
  define :migrate do
    desc 'Run pending migrations'
    alt :m
    example 'db:migrate 3 --pretend'
    opt :pretend, type: :boolean, alias: :p

    proc do |opts|
      step = opts[:args].first || 'all'
      say "migrating #{step} pretend=#{opts[:pretend].inspect}", :green
    end
  end

  namespace :users do
    define :list do
      desc 'List users'
      opt :role, default: 'all'
      opt :limit, type: :integer, default: 100

      proc do |opts|
        say "users role=#{opts[:role]} limit=#{opts[:limit]}", :cyan
      end
    end

    define :create do
      desc 'Create a user'
      opt :email, req: true
      opt :admin, type: :boolean

      proc do |opts|
        say "create #{opts[:email]} admin=#{opts[:admin]}"
      end
    end
  end
end
```

```sh
$ hammer
Usage: demo COMMAND [ARGS]

Commands:
  demo build               # Build the project
  demo deploy (alt: ship)  # Deploy to URL

db:
  demo db:migrate (alt: m)  # Run pending migrations

db:users:
  demo db:users:list       # List users
  demo db:users:create     # Create a user

$ hammer build prod -v
building prod
  verbose on

$ hammer deploy --url=https://example.com --force
building prod
deploying to https://example.com

$ hammer db:m 3 -p           # alt 'm' + positional + short bool
migrating 3 pretend=true

$ hammer db:users:create --email=dino@example.com --admin
create dino@example.com admin=true

$ hammer db                  # bare namespace shows its contents
Usage: demo db:COMMAND [ARGS]

Commands:
  demo db:migrate (alt: m)  # Run pending migrations

users:
  demo db:users:list        # List users
  demo db:users:create      # Create a user

$ hammer db:users:create -h
Usage: demo db:users:create EMAIL [OPTIONS]
  Create a user

Options:
  --email EMAIL (required)
  --admin
```

## Programmatic use

Outside a Hammerfile, you can build a `Hammer` subclass and run it
directly. Useful for embedding or testing:

```ruby
require 'lux-hammer'

class MyCli < Hammer
  program_name 'mycli'

  define :greet do
    opt :loud, type: :boolean
    proc do |opts|
      msg = "hello #{opts[:args].first}"
      say(opts[:loud] ? msg.upcase : msg)
    end
  end
end

MyCli.start(ARGV)         # or:
MyCli.hammer_greet('dino', loud: true)
```

## Development

```sh
git clone https://github.com/dux/hammer
cd lux-hammer
bundle install
bundle exec rake test
```

Tests live in `test/` and use minitest. Run a single file with
`bundle exec ruby -Ilib -Itest test/parser_test.rb`.

## How hammer compares to Thor and Rake

Short version: hammer carves a sweet spot between the two. It's a tiny
CLI builder with Rake's namespacing and a cleaner DSL than Thor, plus a
few small things that have been bugging me about both for years.

### Versus Thor

| | Thor | hammer |
|-|-|-|
| Lines of code | ~6,000 | ~400 |
| Runtime deps | a few | zero |
| Root constants | `Thor`, `Thor::Group`, `Thor::Shell`, `Thor::Actions`, ... | just `Hammer` |
| Command DSL | `desc 'usage', 'help'` + `method_option` + `def name(arg)` | `define :name do ... proc do \|opts\| end end` (or classic `desc` + `def`) |
| Opts container | `Thor::CoreExt::HashWithIndifferentAccess` | plain `Hash` with symbol keys |
| Positional args | method positional params + `method_option`, two parallel systems | declared-order opts fill from positional, single system |
| Sub-namespaces | `register SubClass, 'name', '...'` (inheritance ceremony) | `namespace :name do ... end` (no classes needed) |
| Cross-invoke | `invoke 'name', [args], opts` | `hammer_name(*args, **kwargs)` (looks like a method call) |
| Inline CLI | class only | class DSL **or** `Hammer.run do ... end` block DSL **or** a `Hammerfile` |

**What hammer does better and why:**

* **One root constant.** Thor exposes `Thor`, `Thor::Group`, `Thor::Shell`,
  `Thor::Actions` at the top level - Bundler had to vendor its own copy at
  `Bundler::Thor` to avoid clashes. Hammer is just `Hammer`.
* **The opts hash is just a Hash.** Symbol keys, always. No magic accessor
  object to remember, no string-vs-symbol confusion, no method_missing.
* **Positional args fill opts in declaration order.** Thor either forces
  you into method params (which then clash with options) or makes you read
  `ARGV` yourself. Hammer just says: opts you declared come first, leftover
  goes to `opts[:args]`.
* **Cross-invocation reads as Ruby.** `hammer_db_migrate(env: 'prod')`
  looks like a method call. Thor's `invoke('db:migrate', [], env: 'prod')`
  always feels like reflection.
* **No generator complexity.** Thor's other half is file scaffolding and
  ERB templates. If you don't need that (and most CLIs don't), Thor still
  drags it along.

### Versus Rake

| | Rake | hammer |
|-|-|-|
| Primary use case | build/task automation with file deps | general CLIs |
| Task file | `Rakefile` | `Hammerfile` |
| Namespacing | colon paths (`db:migrate`) | colon paths (`db:migrate`) - parity |
| Per-task options | `task[a,b,c]` positional only | typed `opt`s with flags, aliases, defaults, required |
| Help | `rake -T` (plain list) | bare `hammer` lists everything grouped by namespace; `hammer X -h` for per-command help with examples and defaults |
| Cross-invoke | `Rake::Task['db:migrate'].invoke` | `hammer_db_migrate` |
| Prerequisites | `task :build => [:clean, :compile]` (declarative DAG) | explicit - call `hammer_clean; hammer_compile` in the proc |
| File tasks | yes (mtime-based) | no |
| Aliases | none (workarounds via re-defined tasks) | `alt :short_name` |
| Split across files | `import 'other.rake'` | `load auto: true` (or explicit paths/globs) |

**What hammer does better and why:**

* **Per-command options with types.** Rake's `task[a,b]` syntax is a
  long-standing wart - no types, no validation, awkward to type in the
  shell, no help. `opt :port, type: :integer, default: 3000` is what
  every CLI library has converged on.
* **Help is actually useful.** `hammer build -h` shows usage, options
  with defaults and required markers, and examples. `rake -T` is just a
  list of one-liners.
* **Command aliases.** `alt :m` for `db:migrate` is two characters of
  declaration. Rake makes you redefine the task or use prerequisites.
* **CLI semantics.** Rake assumes "build artifacts from sources"; it's
  great at that. Hammer assumes "give me commands with arguments and
  flags"; it's better at that.

**What Rake does better:**

* **File tasks with mtime tracking.** `file 'foo.o' => 'foo.c' do ... end`
  skips work when the target is newer than the source. Genuine win for
  compilation pipelines. Hammer doesn't have this and isn't going to -
  it's not what a CLI builder is for.

### When to pick which

* **CLI for a tool, app, or service** (run servers, manage data, ship
  releases, scripts your team uses) - **hammer**.
* **Build pipeline with file-mtime dependencies** (compiling assets,
  generating code, classic Make-style work) - **Rake**.
* **Need to ship file generators / templates** (Rails-style
  scaffolding) - **Thor**.

## License

MIT - see [LICENSE](LICENSE).
