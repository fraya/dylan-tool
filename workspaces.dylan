module: workspaces
synopsis: Manage developer workspaces

// TODO:
// * Remove redundancy in 'update' command. It processes (shared?) dependencies
//   and writes registry files multiple times.
// * Display the number of registry files updated and the number unchanged.
//   It gives reassuring feedback that something went right when there's no
//   other output.
// * LID parsing shouldn't map every key to a sequence; only those known to
//   be sequences, like Files:.
// * The output is extremely verbose (including git output), making it easy
//   to miss the important bits. Use the logging library!

// The class of errors explicitly signalled by this module.
define class <workspace-error> (<simple-error>)
end class;

define function workspace-error
    (format-string :: <string>, #rest args)
  error(make(<workspace-error>,
             format-string: format-string,
             format-arguments: args));
end function;

define function print
    (format-string, #rest args)
  apply(format, *stdout*, format-string, args);
  write(*stdout*, "\n");
  // OD doesn't currently have an option for flushing output after \n.
  flush(*stdout*);
end function;

// Whether to display more verbose informational messages.
// May be changed via `configure(verbose?: v)`.
define variable *verbose?* :: <bool> = #f;

define function vprint (format-string, #rest args)
  if (*verbose?*)
    apply(print, format-string, args);
  end;
end function;

define variable *debug?* :: <bool> = #f;

define function debug
    (format-string, #rest args)
  *debug?* & apply(print, concat("*** ", format-string), args)
end function;

ignorable(debug);

// Configure options for this package.  If `verbose?` is true, output
// more informational messages.
define function configure (#key verbose? :: <bool>, debug? :: <bool>) => ()
  *verbose?* := verbose?;
  *debug?* := debug?;
end function;

define constant $workspace-file = "workspace.json";
define constant $default-project-key = "default-project";
define constant $active-key = "active";

define function str-parser (s :: <string>) => (s :: <string>) s end;

// Pulled out into a constant because it ruins code formatting.
define constant $workspace-file-format-string
  = #:str:[{
    %=: {
%s
    }
}
];

// Create a new workspace named `name` with active packages `pkg-names`.
define function new
    (name :: <string>, pkg-names :: <seq>,
     #key parent-directory :: <directory-locator> = fs/working-directory())
  if (workspace-file(directory: parent-directory))
    workspace-error("You appear to already be in a workspace directory: %s",
                    workspace-file);
  end;
  let ws-dir = subdirectory-locator(parent-directory, name);
  let ws-file = as(<file-locator>, "workspace.json");
  let ws-path = merge-locators(ws-file, ws-dir);
  if (fs/file-exists?(ws-dir))
    workspace-error("Directory already exists: %s", ws-dir);
  end;
  fs/ensure-directories-exist(ws-path);
  fs/with-open-file (stream = ws-path,
                     direction: #"output",
                     if-does-not-exist: #"create")
    if (pkg-names.size = 0)
      pkg-names := #["<package-name-here>"];
    elseif (pkg-names.size = 1 & pkg-names[0] = "all")
      pkg-names := as(<vector>, pm/package-names(pm/load-catalog()));
    end;
    format(stream, $workspace-file-format-string,
           $active-key,
           join(pkg-names, ",\n", key: curry(format-to-string, "        %=: {}")));
  end;
  print("Wrote workspace file to %s.", ws-path);
end function;

// Update the workspace based on the workspace config or signal an error.  If
// `update-head?` is true then pull the latest updates for any packages that
// are installed at version $head.
define function update
    (#key update-head? :: <bool>)
  let ws = find-workspace();
  print("Workspace directory is %s.", ws.workspace-directory);
  update-active-packages(ws);
  update-active-package-deps(ws, update-head?: update-head?);
  update-registry(ws);
end function;

// <workspace> holds the parsed workspace configuration, and is the one object
// that knows the layout of the workspace directory:
//       workspace/
//         _build
//         active-package-1/
//         active-package-2/
//         registry/
define class <workspace> (<object>)
  constant slot active-packages :: <istring-table>,
    required-init-keyword: active:;
  constant slot workspace-directory :: <directory-locator>,
    required-init-keyword: workspace-directory:;
  constant slot workspace-registry :: <registry>,
    required-init-keyword: registry:;
  constant slot workspace-default-project-name :: false-or(<string>) = #f,
    init-keyword: default-project-name:;
end class;

// Finds the workspace file somewhere in or above `directory` and creates a
// `<workspace>` from it. `directory` defaults to the current working
// directory.  Signals `<workspace-error>` if the file isn't found.
define function find-workspace
    (#key directory :: false-or(<directory-locator>)) => (w :: <workspace>)
  let path = workspace-file();
  if (~path)
    workspace-error("Workspace file not found."
                      " Current directory isn't under a workspace directory?");
  end;
  fs/with-open-file(stream = path, if-does-not-exist: #"signal")
    let object = json/parse(stream, strict?: #f, table-class: <istring-table>);
    if (~instance?(object, <table>))
      workspace-error("Invalid workspace file %s, must be a single JSON object", path);
    elseif (~element(object, $active-key, default: #f))
      workspace-error("Invalid workspace file %s, missing required key 'active'", path);
    elseif (~instance?(object[$active-key], <table>))
      workspace-error("Invalid workspace file %s, the '%s' element must be a map"
                        " from package name to {...}.",
                      $active-key, path);
    end;
    let registry = make(<registry>, root-directory: locator-directory(path));
    let active = object[$active-key];
    let default = element(object, $default-project-key, default: #f);
    if (~default & active.size = 1)
      for (_ keyed-by project-name in active)
        default := project-name;
      end;
    end;
    make(<workspace>,
         active: object[$active-key],
         workspace-directory: locator-directory(path),
         registry: registry,
         default-project-name: default)
  end
end function;

// Search up from `directory` to find the workspace file. If `directory` is not
// supplied it defaults to the current working directory.
define function workspace-file
    (#key directory :: <directory-locator> = fs/working-directory())
 => (file :: false-or(<file-locator>))
  let ws-file = as(<file-locator>, $workspace-file);
  iterate loop (dir = directory)
    if (dir)
      let file = merge-locators(ws-file, dir);
      if (fs/file-exists?(file))
        file
      else
        loop(dir.locator-directory)
      end
    end
  end
end function;

define function active-package-names
    (ws :: <workspace>) => (names :: <seq>)
  key-sequence(ws.active-packages)
end function;

define function active-package-directory
    (ws :: <workspace>, pkg-name :: <string>) => (d :: <directory-locator>)
  subdirectory-locator(ws.workspace-directory, pkg-name)
end function;

define function active-package-file
    (ws :: <workspace>, pkg-name :: <string>) => (f :: <file-locator>)
  merge-locators(as(<file-locator>, "pkg.json"),
                 active-package-directory(ws, pkg-name))
end function;

define function active-package?
    (ws :: <workspace>, pkg-name :: <string>) => (_ :: <bool>)
  member?(pkg-name, ws.active-package-names, test: istring=?)
end function;

// Download active packages into the workspace directory if the
// package directories don't already exist.
define function update-active-packages
    (ws :: <workspace>)
  for (attrs keyed-by pkg-name in ws.active-packages)
    // Download the package if necessary.
    let pkg-dir = active-package-directory(ws, pkg-name);
    if (fs/file-exists?(pkg-dir))
      vprint("Active package %s exists, not downloading.", pkg-name);
    else
      let cat = pm/load-catalog();
      let rel = pm/find-package-release(cat, pkg-name, pm/$head)
                  | pm/find-package-release(cat, pkg-name, pm/$latest);
      if (rel)
        pm/download(rel, pkg-dir);
      else
        print("WARNING: Skipping active package %s, not found in catalog.", pkg-name);
        print("         If this is a new or private project then this is normal.");
        print("         Create a pkg.json file for it and run update again to update deps.");
      end;
    end;
  end;
end function;

// Update dep packages if needed.
define function update-active-package-deps
    (ws :: <workspace>, #key update-head? :: <bool>)
  for (pkg-name in ws.active-package-names)
    // Update the package deps.
    let rel = find-active-package-release(ws, pkg-name);
    if (rel)
      // TODO: don't do output unless some deps are actually installed. If
      // everything is up-to-date, only print something if --verbose. Probably
      // cleanest to first make a plan and then execute it. Would also
      // facilitate showing the plan and prompting yes/no, and also --dry-run.
      print("Installing deps for package %s.", pkg-name);

      // TODO: in a perfect world this wouldn't install any deps that are also
      // active packages. It doesn't cause a problem though, as long as the
      // registry points to the right place. (This is more easily solved once
      // the above TODO is done: two passes, make plan, execute plan.)
      pm/install-deps(rel /* , skip: ws.active-packages */, update-head?: update-head?);
    else
      print("WARNING: No package definition found for active package %s."
              " Not installing deps.", pkg-name);
    end;
  end for;
end function;

define function find-active-package-release
    (ws :: <workspace>, name :: <string>) => (p :: false-or(pm/<release>))
  let path = active-package-file(ws, name);
  pm/read-package-file(path)
    | begin
        print("WARNING: No package found in %s, falling back to catalog.", path);
        let cat = pm/load-catalog();
        pm/find-package-release(cat, name, pm/$head)
          | begin
              print("WARNING: No %s HEAD version found, falling back to latest.", name);
              pm/find-package-release(cat, name, pm/$latest)
            end
      end
end function;

// Create/update a single registry directory having an entry for each library
// in each active package and all transitive dependencies.  This traverses
// package directories to find .lid files. Note that it assumes that .lid files
// that have no "Platforms:" section are generic, and writes a registry file
// for them (unless they're included in another LID file via the LID: keyword,
// in which case it is assumed they're for inclusion only).
define function update-registry
    (ws :: <workspace>)
  for (name in ws.active-package-names)
    let rel = find-active-package-release(ws, name);
    if (rel)
      let pkg-dir = active-package-directory(ws, name);
      update-for-directory(ws.workspace-registry, pkg-dir);
      pm/do-resolved-deps(rel, curry(update-registry-for-package-release, ws));
    else
      print("WARNING: No package definition found for active package %s."
              " Not creating registry files.", name);
    end;
  end;
end function;

// Dig around in each `pkg`s directory to find the libraries it
// defines and create registry files for them.
define function update-registry-for-package-release
    (ws :: <workspace>, rel :: pm/<release>, dep :: pm/<dep>, installed? :: <bool>)
  if (~installed?)
    workspace-error("Attempt to update registry for dependency %s, which"
                      " is not yet installed. This may be a bug.",
                    pm/package-name(dep));
  end;
  let pkg-dir = if (active-package?(ws, rel.pm/package-name))
                  active-package-directory(ws, rel.pm/package-name)
                else
                  pm/source-directory(rel)
                end;
  update-for-directory(ws.workspace-registry, pkg-dir);
end function;
