Module: dylan-tool-lib
Synopsis: dylan build subcommand


define class <build-subcommand> (<new-subcommand>)
  keyword name = "build";
  keyword help = "Build the configured default libraries.";
end class;

// dylan build [--no-link --clean --unify] [--all | lib1 lib2 ...]
// Eventually need to add more dylan-compiler options to this.
define constant $build-subcommand
  = make(<build-subcommand>,
         options:
           list(make(<flag-option>,
                     names: #("all", "a"),
                     help: "Build all libraries in the workspace."),
                make(<flag-option>,
                     names: #("clean", "c"),
                     help: "Do a clean build."),
                make(<flag-option>,
                     names: #("link", "l"),
                     negative-names: #("no-link"),
                     help: "Link after compiling.",
                     default: #t),
                make(<flag-option>,
                     names: #("unify", "u"),
                     help: "Combine libraries into a single executable."),
                make(<positional-option>,
                     names: #("libraries"),
                     help: "Libraries to build.",
                     repeated?: #t,
                     required?: #f)));

define method execute-subcommand
    (parser :: <command-line-parser>, subcmd :: <build-subcommand>)
 => (status :: false-or(<int>))
  // Blow up early if not in a workspace.

  // TODO: Support lack of workspace.json by looking for _build/ or registry/
  // instead? If no registry directory exists, need to pass the .lid file on
  // the command line.
  let workspace = ws/load-workspace();
  let library-names = get-option-value(subcmd, "libraries") | #[];
  let all? = get-option-value(subcmd, "all");
  if (all?)
    if (~empty?(library-names))
      warn("Ignoring --all option. Using the specified libraries instead.");
    else
      library-names
        := ws/find-active-package-library-names(workspace);
      if (empty?(library-names))
        error("No libraries found in workspace.");
      end;
    end;
  end;
  if (empty?(library-names))
    library-names
      := list(ws/workspace-default-library-name(workspace)
                | error("No default libraries configured."));
  end;
  let dylan-compiler = locate-dylan-compiler();
  for (name in library-names)
    let command = remove(vector(dylan-compiler,
                                "-compile",
                                get-option-value(subcmd, "clean") & "-clean",
                                get-option-value(subcmd, "link") & "-link",
                                get-option-value(subcmd, "unify") & "-unify",
                                name),
                         #f);
    debug("Running command %=", command);
    let exit-status
      = os/run(command,
               under-shell?: #f,
               working-directory: ws/workspace-directory(workspace));
    if (exit-status ~== 0)
      error("Build of %= failed with exit status %=.", name, exit-status);
    end;
  end for;
end method;