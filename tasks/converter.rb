bootstrap_sass = Gem::Specification.find_by_name("bootstrap-sass").gem_dir
require "#{bootstrap_sass}/tasks/converter"

module Patternfly
  class Converter < ::Converter
    BOOTSTRAP_LESS_ROOT = 'components/bootstrap/less'
    PATTERNFLY_LESS_ROOT = 'less'
    PATTERNFLY_COMPONENTS = "../components/patternfly/components"

    # Override
    def initialize(repo: 'patternfly/patternfly',
      cache_path: 'tmp/converter-cache-patternfly',
      branch: 'master',
      test_dir: 'tests/patternfly')
      super(:repo => repo, :cache_path => cache_path)
      @save_to = {:scss => 'sass'}
      @test_dir = test_dir
      get_trees(PATTERNFLY_LESS_ROOT, BOOTSTRAP_LESS_ROOT, 'tests')
    end

    def process_patternfly
      log_status "Convert Patternfly LESS to SASS"
      puts " repo : #@repo_url"
      puts " branch : #@branch_sha #@repo_url/tree/#@branch"
      puts " save to: #{@save_to.to_json}"
      puts " twbs cache: #{@cache_path}"
      puts '-' * 60

      @save_to.values { |v| FileUtils.mkdir_p(v) }

      # process_font_assets
      process_patternfly_less_assets
      # process_javascript_assets
      store_version
      cache_tests
    end

    def remove_xforms(transforms, *rejects)
      transforms.reject do |xform|
        rejects.include?(xform)
      end
    end

    def process_patternfly_less_assets
      log_status "Processing stylesheets..."
      files = read_files(bootstrap_less_files)
      puts(files)
      save_to = @save_to[:scss]

      files.each do |name, file|
        # TODO unify the case statements.  Maybe pass in two procs as
        # callbacks; one for before and one for after.
        #
        # TODO override replace_spin so its regex isn't so over-zealous
        transforms = DEFAULT_TRANSFORMS.dup
        case name
        when 'patternfly.less'
          transforms = remove_xforms(transforms, :replace_spin)
        when 'variables.less'
          transforms = remove_xforms(transforms, :replace_spin)
        when 'spinner.less'
          transforms = remove_xforms(transforms, :replace_spin, :replace_image_urls)
        when 'icons.less'
          transforms = remove_xforms(transforms, :replace_escaping)
        end

        file = convert_less(file, *transforms)

        # Special cases go here
        case name
        when 'mixins.less'
          file = replace_all(
            file,
            /,\s*\.open\s+\.dropdown-toggle& \{(.*?)\}/m,
            " {\\1}\n  .open & { &.dropdown-toggle {\\1} }")
        when 'icons.less'
          # Note the %q to prevent Ruby interpolation
          file = replace_all(
            file,
            %r!\.\$\{(icon-prefix)\}!,
            %q(#{$\\1}\\2))
        when 'patternfly.less'
          file = fix_top_level(file)
          # This is a hack.  We want bootstrap-select to be placed in
          # the final compiled CSS, but Sass doesn't insert a file's contents
          # when that file has a '.css' extension.  Sass just uses a @import
          # statement.  This method moves the bootstrap-select.css into our
          # output directory and renames it with a '.scss' extension.
          add_to_dist(
            "bootstrap-select/bootstrap-select.css",
            "_bootstrap-select.scss")
        when 'spinner.less'
          file = replace_all(
            file,
            %r!"\$(img-path)/!,
            %q("#{$\\1}/))
        end

        name_out = "#{File.basename(name, ".less")}.scss"
        unless name_out == "patternfly.scss"
          name_out = "_#{name_out}"
        end

        path = File.join(save_to, name_out)
        save_file(path, file)
        log_processed(File.basename(path))
      end
    end

    def add_to_dist(name, name_out)
      in_file = File.join('components', name)
      file = read_files([in_file])[in_file]
      out_path = File.join(@save_to[:scss], name_out)
      save_file(out_path, file)
      log_processed(File.basename(out_path))
    end

    def convert_less(less, *transforms)
      load_shared
      less = convert_to_scss(less, *transforms)
      less = yield(less) if block_given?
      less
    end

    DEFAULT_TRANSFORMS = [
      :replace_vars,
      :replace_file_imports,
      :replace_mixin_definitions,
      {:replace_mixins => ["mixins"]},
      :replace_spin,
      # :replace_fadein,
      # :replace_image_urls, # bootstrap-sass does this but we don't need it
      :replace_escaping,
      :convert_less_ampersand,
      :deinterpolate_vararg_mixins,
      :replace_calculation_semantics,
    ]

    def convert_to_scss(file, *transforms)
      # TODO The logging noop is to avoid a warning about an unused variable.
      # We actually are using mixins but we are reading it with an eval.
      # Possibly worth checking the arity of the method represented by xform
      # and send in variable in a defined order based on it? But that limits
      # us to a parameter order that every xform must follow.
      # Something like
      # params = [file, mixins]
      # arity = self.method(xform).arity
      # send(xform, *params[0..arity])
      mixins = @shared_mixins + read_mixins(file)
      silence_log do
        log_status(mixins)
      end
      transforms.each do |xform|
        args = ["file"]
        if xform.is_a?(Hash)
          args.concat(xform.values.first)
          xform = xform.keys.first
        end
        args.map! { |a| "#{eval a}" }
        file = send(xform, *args)
      end
      file
    end

    def fix_top_level(file)
      file = replace_all(
        file,
        %r{../components/font-awesome/less/font-awesome},
        "#{PATTERNFLY_COMPONENTS}/font-awesome/scss/font-awesome")
      file = replace_all(
        file,
        %r{../components/bootstrap-select/bootstrap-select.css},
        "bootstrap-select"
      )
      file = replace_all(
        file,
        %r{../components/bootstrap/less/bootstrap},
        "../components/bootstrap-sass-official/vendor/assets/stylesheets/bootstrap")
      file
    end

    # Override
    def replace_file_imports(less, target_path='')
      less.gsub!(
        %r([@\$]import\s+(?:\(\w+\)\s+)?["|']([\w\-\./]+).less["|'];),
        %Q(@import "#{target_path}\\1";)
      )
      less.gsub!(
        %r([@\$]import\s+(?:\(\w+\)\s+)?["|']([\w\-\./]+).(css)["|'];),
        %Q(@import "#{target_path}\\1.\\2";)
      )
      less
    end

    def cache_tests
      test_files = get_paths_by_directory('tests')
      test_contents = read_files(test_files)
      test_contents.each do |file, content|
        FileUtils.mkdir_p(File.dirname(file))
        save_file(file, content)
      end
    end

    # Override
    # bootstrap-sass uses this method to read in all Bootstrap's less source files
    # We're going to repurpose it.
    def bootstrap_less_files
      patternfly_less_files
    end

    def patternfly_less_files
      get_paths_by_type('less', /\.less$/)
    end

    def load_shared
      mixin_hash = {}
      [BOOTSTRAP_LESS_ROOT, PATTERNFLY_LESS_ROOT].each do |root|
        mixin_hash[root] = read_files(
          get_paths_by_type(root, /mixins\.less$/)).values.join("\n")
      end
      @shared_mixins ||= begin
        read_mixins(mixin_hash.values.join("\n"), :nested => NESTED_MIXINS)
      end
    end

    def store_version
      path = "package.json"
      content = File.read(path)
      # TODO read JSON and set correct version
      File.open(path, 'w') { |f| f.write(content) }
    end

    protected

    # Override
    def get_trees(*args)
      root = get_tree(@branch_sha)['sha']
      @tree_paths = {}
      args.each do |dir|
        path_components = dir.split('/')
        dir_sha = path_components.inject(root) do |tree_sha, component|
          tree_sha = get_tree_sha(component, get_tree(tree_sha))
        end
        hash_list = []
        descend_tree(get_tree(dir_sha), dir, hash_list)
        dir_hash = hash_list.inject({}) do |memo, hash|
          memo.merge(hash)
        end
        @tree_paths.merge!(dir_hash)
      end
      @trees ||= @tree_paths.values
    end

    def descend_tree(tree, path, list)
      list << {path => tree}
      tree['tree'].map do |f|
        if f['type'] == 'tree'
          descend_tree(get_tree(f['sha']), File.join(path, f['path']), list)
        end
      end
    end

    # Override
    def get_paths_by_type(base_dir, regex)
      paths = get_paths_by_directory(base_dir)
      matches = Hash.new([])
      paths.each do |dir, files|
        files.each do |f|
          matches[dir] << f if File.join(dir, f) =~ regex
        end
      end
      matches
    end

    def get_paths_by_directory(dir)
      tree = @tree_paths[dir]
      if tree.nil?
        log_status("#{dir} not found in Git tree.")
        return []
      end

      files = {}
      files[dir] = []
      tree['tree'].map do |f|
        case f['type']
        when 'blob'
          files[dir] << f['path']
        when 'tree'
          loc = File.join(dir, f['path'])
          files.merge!(get_paths_by_directory(loc))
        end
      end
      files
    end

    def get_tree(sha)
      get_json("https://api.github.com/repos/#@repo/git/trees/#{sha}")
    end

    def get_tree_sha(dir, tree=get_trees)
      tree['tree'].find { |t| t['path'] == dir }['sha']
    end

    # Override
    def read_files(files)
      contents = {}
      files.each do |dir, file|
        dir_contents = super(dir, file)
        full_path_contents = Hash[
          dir_contents.map do |k, v|
            [File.join(dir, k), v]
          end
        ]
        contents.merge!(full_path_contents)
      end
      contents
    end
  end
end
