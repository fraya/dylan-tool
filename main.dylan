Module: dylan-tool

// I'm undecided whether to go forward with this tool in the long run
// or to try and use Deft, but I don't want to deal with Deft's
// problems right now so this should be a pretty simple way to get
// workspaces and packages working.

// TODO:
// * Remove redundancy in 'update' command. It processes (shared?) dependencies
//   and writes registry files multiple times.
// * Display the number of registry files updated and the number unchanged.
//   It gives reassuring feedback that something went right when there's no
//   other output.

define function tool-error
    (format-string :: <string>, #rest args)
  error(make(<simple-error>,
             format-string: format-string,
             format-arguments: args));
end;

define function print (format-string, #rest args)
  apply(format, *stdout*, format-string, args);
  write(*stdout*, "\n");
  // OD doesn't currently have an option for flushing output after \n.
  flush(*stdout*);
end;

// May be changed via the --verbose flag.
define variable *verbose* :: <bool> = #f;

define function vprint (format-string, #rest args)
  if (*verbose*)
    apply(print, format-string, args);
  end;
end;

define function debug (format-string, #rest args)
  apply(print, format-string, args)
end;

define constant $workspace-file = "workspace.json";

define function main () => (status :: <int>)
  block (exit)
    // TODO: command parsing is ad-hoc because command-line-parser
    //       doesn't do well with subcommands. Needs improvement.
    let app = locator-name(as(<file-locator>, application-name()));
    local method usage (#key status :: <int> = 2)
            print("Usage: %s install pkg version         -- install a package", app);
            print("       %s new workspace-name [pkg...] -- make a new workspace", app);
            print("       %s update       -- bring workspace up-to-date with workspace.json file", app);
            print("       %s list [--all] -- list installed packages", app);
            print("  Note: a --verbose flag may be added to any subcommand.");
            exit(status);
          end;
    let args = application-arguments();
    if (member?("--help", args, test: istr=)
          | member?("-h", args, test: istr=))
      usage(status: 0);
    end;
    let subcmd = args[0];
    let more-args = slice(args, 1, #f);
    if (member?("--verbose", more-args, test: istr=))
      *verbose* := #t;
    end;
    select (subcmd by istr=)
      "install" =>
        // Install a specific package.
        args.size = 3 | usage();
        let pkg-name = args[1];
        let vstring = args[2];
        let pkg = pm/find-package(pm/load-catalog(), pkg-name, vstring);
        if (~pkg)
          error("Package %s not found.", pkg-name);
        end;
        pm/install(pkg);
      "list" =>
        list-catalog(all?: member?("--all", args, test: istr=));
      "new" =>                  // Create a new workspace.
        args.size >= 2 | usage();
        apply(new, app, args[1], slice(args, 2, #f));
      "update" =>
        args.size = 1 | usage();
        update();        // Update the workspace based on config file.
      otherwise =>
        usage();
    end select;
    0
/* TODO: turn this into a 'let handler' that can be turned off by a --debug flag.
  exception (err :: <error>)
    print("Error: %s", err);
    1
*/
  end
end function main;

// List installed package names, synopsis, versions, etc. If `all` is
// true, show all packages.
define function list-catalog (#key all? :: <bool>)
  let cat = pm/load-catalog();
  for (pkg-name in sort(pm/package-names(cat)))
    let versions = pm/installed-versions(pkg-name, head?: #f);
    let latest-installed = versions.size > 0 & versions[0];
    let entry = pm/find-entry(cat, pkg-name);
    let latest = pm/find-package(cat, pkg-name, pm/$latest);
    let needs-update? = latest-installed & latest
                          & (pm/version(latest) ~= pm/$head)
                          & (latest-installed < pm/version(latest));
    if (all? | latest-installed)
      print("%s%s (latest: %s) - %s",
            pkg-name,
            iff(needs-update?, "*", ""),
            pm/version(latest),
            pm/synopsis(entry));
    end;
  end;
end;

define function str-parser (s :: <string>) => (s :: <string>) s end;

// Pulled out into a constant because it ruins code formatting.
define constant $workspace-file-format-string = #str:[{
    "active": {
%s
    }
}
];

define function new (app :: <string>, workspace-name :: <string>, #rest pkg-names)
  let workspace-file = find-workspace-file(fs/working-directory());
  if (workspace-file)
    error("You appear to already be in a workspace directory: %s", workspace-file);
  end;
  let workspace-dir = subdirectory-locator(fs/working-directory(), workspace-name);
  let workspace-file = as(<file-locator>, "workspace.json");
  let workspace-path = merge-locators(workspace-file, workspace-dir);
  if (fs/file-exists?(workspace-dir))
    error("Directory already exists: %s", workspace-dir);
  end;
  fs/ensure-directories-exist(workspace-path);
  fs/with-open-file (stream = workspace-path,
                     direction: #"output",
                     if-does-not-exist: #"create")
    if (pkg-names.size = 0)
      pkg-names := #["<package-name-here>"];
    end;
    format(stream, $workspace-file-format-string,
           join(pkg-names, ",\n", key: curry(format-to-string, "        %=: {}")));
  end;
  print("Wrote workspace file to %s.", workspace-path);
  print("You may now run '%s update' in the new directory.", app);
end;

// Update the workspace based on the workspace config or signal an error.
define function update ()
  let config = load-workspace-config($workspace-file);
  print("Workspace directory is %s.", config.workspace-directory);
  update-active-packages(config);
  update-active-package-deps(config);
  update-registry(config);
end;

// <config> holds the parsed workspace configuration file, and is the one object
// that knows the layout of the workspace directory.  That is,
//       workspace/
//         registry/
//         active-package-1/
//         active-package-2/
define class <config> (<object>)
  constant slot active-packages :: <istring-table>, required-init-keyword: active:;
  constant slot workspace-directory :: <directory-locator>, required-init-keyword: workspace-directory:;
end;

define function load-workspace-config (filename :: <string>) => (c :: <config>)
  let path = find-workspace-file(fs/working-directory());
  if (~path)
    error("Workspace file not found. Current directory isn't under a workspace directory?");
  end;
  fs/with-open-file(stream = path, if-does-not-exist: #"signal")
    let object = json/parse(stream, strict?: #f, table-class: <istring-table>);
    if (~instance?(object, <table>))
      error("Invalid workspace file %s, must be a single JSON object", path);
    elseif (~element(object, "active", default: #f))
      error("Invalid workspace file %s, missing required key 'active'", path);
    elseif (~instance?(object["active"], <table>))
      error("Invalid workspace file %s, the 'active' element must be a map"
              " from package name to {...}.", path);
    end;
    make(<config>,
         active: object["active"],
         workspace-directory: locator-directory(path))
  end
end;

// Search up from `dir` to find $workspace-file.
define function find-workspace-file
   (dir :: <directory-locator>) => (file :: false-or(<file-locator>))
  if (~root-directory?(dir))
    let path = merge-locators(as(fs/<file-system-file-locator>, $workspace-file), dir);
    if (fs/file-exists?(path))
      path
    else
      locator-directory(dir) & find-workspace-file(locator-directory(dir))
    end
  end
end;

// TODO: Put something like this in system:file-system?  It seems
// straight-forward once you figure it out, but it took a few tries to
// figure out that root-directories returned locators, not strings,
// and it seems to depend on locators being ==, which I'm not even
// sure of. It seems to work.
define function root-directory? (loc :: <locator>)
  member?(loc, fs/root-directories())
end;

define function active-package-names (conf :: <config>) => (names :: <seq>)
  key-sequence(conf.active-packages)
end;

define function active-package-directory
    (conf :: <config>, pkg-name :: <string>) => (d :: <directory-locator>)
  subdirectory-locator(conf.workspace-directory, pkg-name)
end;

define function active-package-file
    (conf :: <config>, pkg-name :: <string>) => (f :: <file-locator>)
  merge-locators(as(<file-locator>, "pkg.json"),
                 active-package-directory(conf, pkg-name))
end;

define function active-package? (conf :: <config>, pkg-name :: <string>) => (_ :: <bool>)
  member?(pkg-name, conf.active-package-names, test: istr=)
end;

define function registry-directory (conf :: <config>) => (d :: <directory-locator>)
  subdirectory-locator(conf.workspace-directory, "registry")
end;

// Download active packages into the workspace directory if the
// package directories don't already exist.
define function update-active-packages (conf :: <config>)
  for (attrs keyed-by pkg-name in conf.active-packages)
    // Download the package if necessary.
    let pkg-dir = active-package-directory(conf, pkg-name);
    if (fs/file-exists?(pkg-dir))
      vprint("Active package %s exists, not downloading.", pkg-name);
    else
      let cat = pm/load-catalog();
      let pkg = pm/find-package(cat, pkg-name, pm/$head)
                  | pm/find-package(cat, pkg-name, pm/$latest);
      if (pkg)
        pm/download(pkg, pkg-dir);
      else
        print("WARNING: Skipping active package %s, not found in catalog.", pkg-name);
        print("WARNING: If this is a new or private project then this is normal.");
        print("WARNING: Create a pkg.json file for it and run update again to update deps.");
      end;
    end;
  end;
end;

// Update dep packages if needed.
define function update-active-package-deps (conf :: <config>)
  debug(" *** update-active-package-deps");
  for (pkg-name in conf.active-package-names)
    debug(" ***   pkg-name = %=", pkg-name);
    // Update the package deps.
    let pkg = pm/read-package-file(active-package-file(conf, pkg-name));
    if (pkg)
      print("Installing deps for package %s.", pkg-name);
      // TODO: in a perfect world this wouldn't install any deps that
      // are also active packages. It doesn't cause a problem though,
      // as long as the registry points to the right place.
      pm/install-deps(pkg /* , skip: conf.active-package-names */);
    else
      print("WARNING: No pkg.json file found for active package %s."
              " Not installing deps.", pkg-name);
    end;
  end;
end;

// Create/update a single registry directory having an entry for each
// library in each active package and all transitive dependencies.
define function update-registry (conf :: <config>)
  for (pkg-name in conf.active-package-names)
    let pkg-file = active-package-file(conf, pkg-name);
    let pkg = pm/read-package-file(pkg-file);
    if (~pkg)
      print("WARNING: No package found in %s, falling back to catalog"
              " to find deps.", pkg-file);
      let cat = pm/load-catalog();
      pkg := pm/find-package(cat, pkg-name, pm/$head)
               | pm/find-package(cat, pkg-name, pm/$latest);
    end;
    if (pkg)
      let pkg-dir = active-package-directory(conf, pkg-name);
      update-registry-for-directory(conf, pkg-dir);
      pm/do-resolved-deps(pkg, curry(update-registry-for-package, conf));
    else
      print("WARNING: No pkg.json file found for active package %s."
              " Not creating registry files.", pkg-name);
    end;
  end;
end;

// Dig around in each `pkg`s directory to find the libraries it
// defines and create registry files for them.
define function update-registry-for-package (conf, pkg, dep, installed?)
  if (~installed?)
    error("Attempt to update registry for dependency %s, which"
            " is not yet installed. This may be a bug.", dep);
  end;
  let pkg-dir = if (active-package?(conf, pkg.pm/name))
                  active-package-directory(conf, pkg.pm/name)
                else
                  pm/source-directory(pkg)
                end;
  update-registry-for-directory(conf, pkg-dir);
end;

// Find all the .lid files in `pkg-dir` that are marked as being for
// the current platform and create registry files for the
// corresponding libraries.
define function update-registry-for-directory (conf, pkg-dir)
  local method doit (dir, name, type)
          select (type)
            #"file" =>
              if (ends-with?(name, ".lid"))
                let lid-path = merge-locators(as(<file-locator>, name), dir);
                update-registry-for-lid(conf, lid-path);
              end;
            #"directory" =>
              // ., .., .git, etc.  Could be too broad a brush, but it's hard to imagine
              // putting Dylan code in .foo directories?
              if (~starts-with?(name, "."))
                let subdir = subdirectory-locator(dir, name);
                fs/do-directory(doit, subdir);
              end;
            #"link" => #f;
          end;
        end;
  fs/do-directory(doit, pkg-dir);
end;

define function update-registry-for-lid
    (conf :: <config>, lid-path :: <file-locator>)
  let lid = parse-lid-file(lid-path);
  let platform = lowercase(as(<string>, os/$platform-name));
  let lid-platforms = element(lid, #"platforms", default: #f);
  if (lid-platforms & ~member?(platform, lid-platforms, test: str=))
    vprint("Skipped, not %s: %s", platform, lid-path);
  else
    let directory = subdirectory-locator(conf.registry-directory, platform);
    let lib = lid[#"library"][0];
    let reg-file = merge-locators(as(<file-locator>, lib), directory);
    let relative-path = relative-locator(lid-path, conf.workspace-directory);
    let new-content = format-to-string("abstract:/" "/dylan/%s\n", relative-path);
    let old-content = file-content(reg-file);
    if (new-content ~= old-content)
      debug(" *** old-content = %=\n     new-content = %=", old-content, new-content);
      fs/ensure-directories-exist(reg-file);
      fs/with-open-file(stream = reg-file, direction: #"output", if-exists?: #"overwrite")
        write(stream, new-content);
      end;
      print("Wrote %s", reg-file);
    end;
  end;
end;

// Read the full contents of a file and return it as a string.
// If the file doesn't exist return #f. (I thought if-does-not-exist: #f
// was supposed to accomplish this without the need for block/exception.)
define function file-content (path :: <locator>) => (s :: false-or(<string>))
  block ()
    fs/with-open-file(stream = path, if-does-not-exist: #"signal")
      read-to-end(stream)
    end
  exception (e :: fs/<file-does-not-exist-error>)
    debug(" *** couldn't read %s", path);
    #f
  end
end;

define constant $keyword-line-regex = #regex:"^([a-zA-Z0-9-]+):[ \t]+(.+)$";

// Parse a .lid file into an table mapping keyword symbols to
// sequences of values. e.g., #"files" => #["foo.dylan", "bar.dylan"]
define function parse-lid-file (path :: <file-locator>) => (lid :: <table>)
  parse-lid-file-into(path, make(<table>))
end;

define function parse-lid-file-into (path :: <file-locator>, lid :: <table>) => (lid :: <table>)
  let line-number = 0;
  let prev-key = #f;
  fs/with-open-file(stream = path)
    let line = #f;
    while (line := read-line(stream, on-end-of-stream: #f))
      inc!(line-number);
      if (strip(line) ~= ""     // tolerate blank lines
            & ~starts-with?(strip(line), "//"))
        if (starts-with?(line, " ") | starts-with?(line, "\t"))
          // Continuation line
          if (prev-key)
            let value = strip(line);
            if (~empty?(value))
              lid[prev-key] := add!(lid[prev-key], value);
            end;
          else
            vprint("Skipped unexpected continuation line %s:%d", path, line-number);
          end;
        else
          // Keyword line
          let (whole, keyword, value) = re/search-strings($keyword-line-regex, line);
          if (whole)
            value := strip(value);
            let key = as(<symbol>, keyword);
            if (key = #"LID")
              let path = merge-locators(as(<file-locator>, value), locator-directory(path));
              parse-lid-file-into(path, lid);
              prev-key := #f;
            else
              lid[key] := vector(value);
              prev-key := key;
            end;
          else
            vprint("Skipped invalid syntax line %s:%d: %=", path, line-number, line);
          end;
        end;
      end;
    end;
  end;
  if (~element(lid, #"library", default: #f))
    tool-error("LID file %s has no Library: property.", path);
  end;
  if (~element(lid, #"files", default: #f))
    print("LID file %s has no Files: property.", path);
  end;
  lid
end function parse-lid-file-into;

exit-application(main());
