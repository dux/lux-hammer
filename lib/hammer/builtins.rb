class Hammer
  # Lazy-loaded "built-ins" attached under the reserved `self:` namespace
  # of the `hammer` binary. Hosts management commands (recipes, AGENTS.md
  # dump, self-update) that should not appear on every user-command run.
  # `Hammer.cli` only calls `register` when argv shows the user is
  # asking for help or invoking a `self:`-prefixed command.
  module Builtins
    module_function

    # Wire the `self:` namespace into `klass`. Idempotent - safe to call
    # twice; the second call replaces the existing subclass.
    def register(klass)
      Thread.current[:hammer_builtins_loading] = true
      klass.namespace(:self) do
        task :ai do
          desc 'Print AGENTS.md (AI-friendly Hammerfile authoring docs)'
          proc { Hammer.print_ai_help }
        end

        task :update do
          desc 'Update lux-hammer from github main (requires install.sh checkout)'
          proc { Hammer.self_update }
        end

        task :recipe do
          desc <<~TXT
            Manage recipes. First positional argument is the action.

              (no args)              list all recipes
              install [NAME] [PATH]  install stub. No PATH: print to stdout. With PATH: write + chmod +x.
              show    NAME           cat recipe source
              path    NAME           print recipe abs path
              edit    NAME           open recipe in $EDITOR
              run     NAME [ARGS]    run a recipe without installing its bin
          TXT
          example 'self:recipe'
          example 'self:recipe install srt ~/bin/srt        # write + chmod in one shot'
          example 'self:recipe install srt > ~/bin/srt && chmod +x $_'
          example 'self:recipe show srt'
          example 'self:recipe run srt extract movie.mp4'
          example 'self:recipe run srt -- --help            # -- forwards flags to the recipe'
          proc do |opts|
            action, name, *rest = opts[:args]
            Hammer::Builtins::Recipes.dispatch(action, name, rest)
          end
        end
      end
    ensure
      Thread.current[:hammer_builtins_loading] = nil
    end

    # Implementations of the `self:recipe <action>` sub-commands, plus
    # the no-action listing view. Kept in its own module so the
    # namespace definition above stays small and skimmable.
    module Recipes
      module_function

      def dispatch(action, name, rest = [])
        case action
        when nil       then list
        when 'install' then install(name, rest.first)
        when 'show'    then show(require_name!(name, 'show'))
        when 'path'    then path(require_name!(name, 'path'))
        when 'edit'    then edit(require_name!(name, 'edit'))
        when 'run'     then Hammer.recipe(require_name!(name, 'run'), rest)
        else
          Shell.print_error "unknown action: #{action}"
          Shell.say 'valid: install, show, path, edit, run (or omit for list)', :yellow
          exit 1
        end
      end

      def require_name!(name, action)
        return name if name
        Shell.print_error "missing recipe name (usage: self:recipe #{action} NAME)"
        exit 1
      end

      # Group by source dir; each row shows desc and installed-or-not.
      def list
        groups = Hammer::Recipe.grouped
        if groups.empty?
          Shell.say 'no recipes found', :gray
          return
        end

        rows = Hammer::Recipe.all.map do |name, path|
          [name, Hammer::Recipe.desc(path), Hammer::Recipe.installed_path(name)]
        end
        width = rows.map { |n, _, _| n.length }.max

        groups.each_with_index do |(source, items), i|
          Shell.say '' if i > 0
          Shell.say "#{source}:", :yellow
          items.each_key do |name|
            _n, desc, installed = rows.find { |r| r.first == name }
            status = installed ? "(installed: #{installed})" : "[install: hammer self:recipe install #{name}]"
            line = "  #{name.ljust(width)}  # #{desc}"
            Shell.say line
            Shell.say "  #{' ' * width}    #{status}", :gray
          end
        end
      end

      # With no NAME: arrow-key picker. With NAME only: print the stub
      # to stdout (user pipes it themselves). With NAME + TARGET: write
      # the stub to TARGET and chmod +x in one shot.
      def install(name, target = nil)
        if name.nil?
          names = Hammer::Recipe.all.keys.sort
          if names.empty?
            Shell.print_error 'no recipes available'
            exit 1
          end
          idx = Shell.choose('pick a recipe to install', names)
          exit 1 if idx.nil?
          name = names[idx]
        end

        unless Hammer::Recipe.path(name)
          Shell.print_error "unknown recipe: #{name}"
          exit 1
        end

        stub = Hammer::Recipe.stub(name)
        if target
          path = File.expand_path(target)
          File.write(path, stub)
          File.chmod(0o755, path)
          Shell.say "installed #{name} -> #{path}", :green
        else
          puts stub
        end
      end

      def show(name)
        path = Hammer::Recipe.path(name) or fail_unknown(name)
        puts File.read(path)
      end

      def path(name)
        path = Hammer::Recipe.path(name) or fail_unknown(name)
        puts path
      end

      # For a gem recipe, offer to copy to user dir first so edits
      # survive `hammer self:update`. Then exec $EDITOR on the file.
      def edit(name)
        path = Hammer::Recipe.path(name) or fail_unknown(name)
        editor = ENV['EDITOR'] || ENV['VISUAL']
        unless editor
          Shell.print_error '$EDITOR not set'
          exit 1
        end

        if path.start_with?(Hammer::Recipe::GEM_DIR)
          user_dir = ENV['HAMMER_RECIPES_DIR'] || File.expand_path('~/.config/hammer/recipes')
          target = File.join(user_dir, "#{name}.rb")
          unless File.exist?(target)
            if Shell.yes?("copy gem recipe to #{target} before editing? (recommended)")
              require 'fileutils'
              FileUtils.mkdir_p(user_dir)
              FileUtils.cp(path, target)
              Shell.say "copied to #{target}", :green
              path = target
            end
          else
            path = target
          end
        end

        system(editor, path)
      end

      def fail_unknown(name)
        Shell.print_error "unknown recipe: #{name}"
        exit 1
      end
    end
  end
end
