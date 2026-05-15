# AGENTS.md - lux-hammer

Conventions and constraints for AI agents working on this gem.

## What this gem is

A tiny Thor-inspired CLI builder. Users drop a `Hammerfile` in their
project, run `hammer`, get a structured CLI. Also usable as a library
(`require 'lux-hammer'`, subclass `Hammer`, call `.start(ARGV)`).

## Hard constraints

* **One root constant**: `Hammer`. Never pollute `Object` or introduce
  another top-level constant. Sub-types live as `Hammer::Shell`,
  `Hammer::Option`, `Hammer::Parser`, `Hammer::Command`,
  `Hammer::Loader`, `Hammer::Builder`, `Hammer::CommandBuilder`.
* **Zero runtime dependencies**. The gem must work with stdlib only. New
  dependencies require explicit user approval.
* **Ruby >= 2.7**. Do not use language features introduced after 2.7
  without flagging.
* **`desc` is single-arg, multi-line allowed**. The argument is one
  string; it may contain newlines. The first line is the brief shown in
  command listings, the full string renders (indented) in per-command
  help. Trailing whitespace is stripped so heredocs work cleanly. `desc`
  is never multi-arg - that form was tried and reverted.
* **The `proc` is the trailing expression of a `define` block.** Do not
  introduce `run do ... end` or similar - the user explicitly chose this.

## File layout

```
bin/hammer                  # CLI entry point
lib/lux-hammer.rb           # Entry - defines class Hammer and its DSL
lib/hammer/shell.rb         # ANSI/IO helpers
lib/hammer/option.rb        # One option definition
lib/hammer/parser.rb        # ARGV -> [positional, opts_hash]
lib/hammer/command.rb       # One registered command (name, opts, alts, handler)
lib/hammer/loader.rb        # `*_hammer.rb` fragment loader (auto/glob/file)
lib/hammer/builder.rb       # Block-DSL context (Hammerfile / Hammer.run)
lib/hammer/command_builder.rb # `define :name do ... end` context
test/dsl_test.rb            # DSL surface, dispatch, help formatting
test/load_test.rb           # `load` / `*_hammer.rb` fragment loader
test/parser_test.rb         # ARGV parsing edge cases
test/option_test.rb         # Option declaration / casting
test/command_test.rb        # Command data type
test/shell_test.rb          # ANSI / IO helpers
test/cli_test.rb            # `hammer` binary end-to-end
examples/Hammerfile         # Reference Hammerfile
examples/class_dsl.rb       # Reference class DSL usage
examples/block_dsl.rb       # Reference block DSL usage
```

## DSL surface (do not break compatibility silently)

Inside a `define :name do ... end` block (CommandBuilder context):

* `desc 'short description'` (string may contain `\n`; first line is
  the brief shown in listings, full text renders in per-command help)
* `example 'invocation example'` (callable many times)
* `opt :name, type:, default:, alias:, desc:, req:` - any other kwarg
  raises `Hammer::Error` ("unknown opt parameter(s)")
* `alt :other_name` (callable many times)
* `proc do |opts| ... end` - **the last expression**, becomes handler

At class scope (for `def`-style commands):

* `desc`, `example`, `opt`, `alt` set pending state
* The next `def` consumes the pending state IF `desc` was set; otherwise
  the method is treated as a plain helper
* Methods with arity 0 are called without opts; methods that take an arg
  receive the opts hash

At class or `Hammerfile` scope:

* `program_name 'foo'` / `program 'foo'` - optional. Default is the
  invocation path relative to cwd if the bin lives inside cwd
  (e.g. `bin/foo` when invoked from the project root), otherwise the
  basename of `$PROGRAM_NAME` (e.g. `lux` for a global bin in PATH).
* `define :name do ... end`
* `namespace :name do ... end`
* `load` / `load auto: true` / `load 'path/file.rb'` / `load 'glob/*.rb'` -
  pull in Hammerfile fragments from `*_hammer.rb` files. Paths resolve
  relative to the caller's file. Fragments are de-duplicated per
  target class, so re-entrant `load` is safe. Skipped dirs:
  `.git`, `.bundle`, `node_modules`, `tmp`, `vendor`, `dist`, `build`,
  `coverage`, plus any hidden dir. Fragment shape is the block DSL
  (`define`, `namespace`); class-DSL fragments belong in plain `.rb`
  files loaded with `require_relative`.

Runtime cross-invocation:

* `hammer_<colon_path>(*args, **kwargs)` - underscores in name become
  colons, underscores in kwarg keys become dashes, boolean kwargs become
  `--flag`/`--no-flag`

## `opts` hash contract

Always a `Hash` with **symbol keys**. Never change this without an
explicit ADR-level discussion. Keys:

* one per declared option
* `opts[:args]` - leftover positional ARGV (after declaration-order
  fill)

## Dispatch model

* Commands are addressed by colon path: `db:users:list`.
* The root `Hammer` subclass holds `@commands` and `@namespaces`.
* `resolve('a:b:c')` walks `@namespaces['a'].namespaces['b']` and
  finds command `c` in the last class.
* There is **no per-level dispatch**. A namespace is a container, not a
  CLI of its own. Do not reintroduce `subclass.start(remaining_argv)`.

## Help formatting

* `hammer` (no args), `hammer -h`, and `hammer --help` all print top-level help.
* `hammer COMMAND -h` / `--help` prints per-command help (reserved on every command).
* Commands listed flat with colon paths, grouped by top-level namespace.
* Bare namespace (`hammer db`) prints the same listing scoped to that
  namespace.
* Per-command help: usage line shows declared opts inline (required
  bare, optional bracketed), then options with `(default: ...)` /
  `(required)` annotations, then examples.

## Error handling

* `Hammer::Shell.error 'msg'` raises `Hammer::Error`. The dispatcher
  catches it inside `run_command`, prints `[error] msg` in red to
  stderr, and exits 1 - no backtrace, no per-command help.
* `Hammer::Shell.print_error 'msg'` prints without raising; reserved
  for the dispatcher's own diagnostics (unknown command, missing
  Hammerfile).
* `Hammer::Parser::Error` is also caught in `run_command` and
  additionally prints per-command help (because the input *was* aimed
  at that command).
* Inside a handler, just call `error 'msg'` - it resolves via the
  `Shell` mixin.

## Coding rules

* No trailing spaces on empty lines. End every file with a newline.
* Use ASCII only - `-`, not unicode dashes; `*` for bullets in docs.
* Preserve existing style. Minimize diff size.
* Comments only when the *why* is non-obvious. Don't restate the code.
* No `// removed` markers - delete cleanly.
* Constants: prefer `FOO ||=` over `FOO =` (re-load safety).
* Never commit or push without explicit confirmation.

## Testing

* Run: `bundle exec rake test`
* Single file: `bundle exec ruby -Ilib -Itest test/parser_test.rb`
* Single test by name: `... test/parser_test.rb -n test_boolean_via_short_alias`
* Helper `CaptureIO` in `test/test_helper.rb` swaps `$stdout`/`$stderr`
  for `StringIO`. Use `capture { ... }` for non-exiting code and
  `capture_exit { ... }` for code that calls `exit`.

When you add a feature, add a test in the matching `_test.rb`. When you
fix a bug, write the failing test first.

## What NOT to do

* Don't add command-level prerequisites (`task :build => [:clean]`)
  unless explicitly asked - the convention is `hammer_clean` inside
  the dependent's proc.
* Don't add generators / templates (Thor-style file scaffolding).
* Don't add shell-completion generation to core - that belongs in a
  separate plugin gem.
* Don't introduce a class hierarchy for commands. Commands are data
  (`Hammer::Command` instances), not classes.
* Don't propagate `program_name` into namespaces as a longer prefix -
  there is only one program name.
* Don't make `desc` multi-arg again (it once took `usage, description`
  - that was reverted intentionally).
* Don't add a `subcommand 'name', SomeClass` form - it was replaced by
  `namespace :name do ... end` intentionally.
* Don't auto-namespace fragments by filename (e.g. `db_hammer.rb` does
  not implicitly wrap in `namespace :db do ... end`). Be explicit, as
  Rake's `import` is. If a fragment wants a namespace, it writes it.

## When in doubt

* Read `lib/lux-hammer.rb` top-to-bottom. It's the whole DSL surface.
* Run the example: `cd examples && ruby -I../lib ../bin/hammer`
* Check `test/dsl_test.rb` for the canonical behavior of each feature.
* Check `test/load_test.rb` for `load` / fragment loader behavior.
