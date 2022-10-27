{ inputs =
    { get-flake.url = "github:ursi/get-flake";

      npmlock2nix =
        { flake = false;
          url = "github:nix-community/npmlock2nix";
        };

      purs-nix-test-packages =
        { flake = false;
          url = "github:purs-nix/test-packages";
        };
    };

  outputs = { get-flake, purs-nix-test-packages, ... }@inputs:
    with builtins;
    let purs-nix-flake = get-flake ../.; in
    purs-nix-flake.inputs.utils.apply-systems
      { inputs =
          inputs
          // { purs-nix = purs-nix-flake;
               inherit (purs-nix-flake.inputs) make-shell nixpkgs ps-tools;
             };

        systems = [ "x86_64-linux" ];
      }
      ({ make-shell, pkgs, ps-tools, system, ... }:
         let
           purs-nix =
             purs-nix-flake
               { inherit system;

                 overlays =
                   [ (_: super: assert !super?test-package; {})

                     (self: super:
                        with self;
                        { inherit (super) console;

                          effect =
                            { src.path = purs-nix-test-packages;
                              info = /effect/package.nix;
                            };

                          # testing overlay precedence
                          murmur3 = prelude;

                          # test if later overlays have access to this package
                          test-package = prelude;
                        }
                     )

                     (self: super:
                        with self;
                        { murmur3 = self."ursi.murmur3";
                          "test.prelude" = super.test-package;
                        }
                     )
                   ];
               };

           minimal = false;

           switches =
             mapAttrs
               (n: v: (a: l.warnIf (!a) "switches.${n} == false" a) (!minimal && v))
               { packages-compile = true;
                 parser = true;
                 repl = true;
               };

           l = p.lib; p = pkgs;
           inherit (purs-nix) ps-pkgs ps-pkgs-ns purs;
           package = import ./package.nix purs-nix;

           ps-custom = { dir ? ./., ...}@args:
             purs
               ({ inherit (package) dependencies;
                  test-dependencies =
                    [ ps-pkgs."assert"
                      ps-pkgs-ns.ursi.murmur3
                    ];

                  srcs = [ "src" "src2" ];

                  foreign =
                    { IsNumber.node_modules =
                        (p.callPackages inputs.npmlock2nix {})
                        .node_modules { src = ./foreign-js; } + /node_modules;

                      Nested.src = ./foreign-js;
                    };
                }
                // (if dir == null then {} else { inherit dir; })
                // (removeAttrs args [ "dir" ])
               );

           ps = ps-custom {};

           ps2 =
             purs
               { dependencies =
                   let inherit (ps-pkgs-ns) test; in
                   with ps-pkgs;
                   [ console
                     effect
                     murmur3
                     test.prelude
                   ];

                  test-dependencies = [ ps-pkgs."assert" ];
                  srcs = [ ./src3 ];
               };

           run-app-custom = args: module:
             "${(ps-custom args).modules.${module}.app { name = "test run"; }}/bin/'test run'";

           run-app = run-app-custom {};

           make-test = description: info: test:
             ''
             echo TEST: ${l.escapeShellArg description}
             ${info}
             ${test "$(${info})"}
             echo
             '';

           package-tests =
             import ./packages.nix
               ({ inherit l p switches;
                  inherit (purs-nix-flake.inputs.parsec.lib) parsec;
                }
                // (purs-nix-flake { inherit system; })
               );

           expected-output-tail =
             ''
             argument
             prelude override
             effect override
             2 is even
             3 isn't even
             1.2 is a number
             foreign1
             foreign2
             build test
             ❄'';

           expected-output = i:
             ''
             target="test run
             ${expected-output-tail}"

             [[ ${i} == $target ]]
             '';
         in
         { apps.default =
             { type = "app";

               program =
                 let
                   path =
                     package-tests."compiled packages bucket 1"
                     + /cache-db.json;
                 in
                 (p.writeScript "inspect-packages"
                    "${p.jq}/bin/jq . ${path} | less"
                 ).outPath;
             };

           checks =
             mapAttrs
               (n: v: p.runCommand n {} "${v}\ntouch $out")
               { "compiler flags" =
                   let
                     output =
                       ps.modules.Main.output
                         { codegen = "corefn,js";
                           comments = true;
                           no-prefix = true;
                         };
                   in
                   make-test "codegen"
                     ""
                     (_: "ls ${output}/Main/corefn.json") +

                   make-test "comments"
                      ''grep "// a comment for testing purposes" ${output}/Main/index.js''
                      (i: "[[ ${i} ]]") +

                   make-test "no-prefix"
                     "echo $(head -n 1 ${output}/Main/index.js | grep //)"
                     (i: "[[ -z ${i} ]]");

                 "custom node package" =
                   # don't pull this out into its own project, it is also a test for
                   # 2f5285a97c9a575e70bebf8e614fff3a42b0fe68
                   let nodejs = p.nodejs-14_x; in
                   make-test "node version"
                     (run-app-custom { inherit nodejs; } "Node")
                     (i: "[[ ${i} == v${nodejs.version} ]]");

                 "custom purescript package" =
                   let
                     output =
                         (ps-custom { inherit purescript; }).modules.Main.output {};

                     purescript = ps-tools.purescript-0_15_0;
                   in
                   make-test "purescript version"
                     "head -n 1 ${output}/Main/index.js"
                     (i: ''[[ ${i} == "// Generated by purs version ${substring 1 99 purescript.version}" ]]'');

                 "main app output" =
                   make-test "expected output"
                     "${run-app "Main"} argument"
                     expected-output;

                 "main script output head" =
                   make-test "expected output"
                     "head -n 1 <(${ps.modules.Main.script {}})"
                     (i: ''[[ ${i} == *-Main-script ]]'');

                 "main script output tail" =
                   make-test "expected output"
                     "tail -n +2 <(${ps.modules.Main.script {}} argument)"
                     (i: ''[[ ${i} == "${expected-output-tail}" ]]'');

                 "main output murmur3" =
                   make-test "expected output"
                     "${ps2.modules.Main.app { name = "_"; }}/bin/_"
                     (i: "[[ ${i} == 1945310157 ]]");

                 "app minification" =
                   let a = args: ps.modules.Main.app ({ name = "_"; } // args); in
                   ''
                   a=$(wc -c < ${a {}}/bin/_)
                   b=$(wc -c < ${a { esbuild.minify = false; }}/bin/_)
                   echo $a
                   echo $b
                   (( $a < $b ))
                   '';

                 "ps.dependencies" =
                   make-test "expected number"
                     "echo ${toString (length ps.dependencies)}"
                     (i: "[[ ${i} == 48 ]]");

                 "test run defaults" =
                   make-test "expected output"
                     "${ps.test.run {}}"
                     (i: "[[ ${i} == testing ]]");

                 "test run configured" =
                   make-test "expected output"
                     "${(ps-custom { test = "test-dir"; test-module = "Test.Test"; })
                          .test.run {}
                      }"
                     (i: "[[ ${i} == testing ]]");

                 "no test app" =
                   make-test "expected output"
                     "${(ps-custom { test = "nonexistent"; })
                          .modules.Main.app { name = "test run"; }
                      }/bin/'test run' argument"
                      expected-output;

                 "no dir app" =
                   make-test "expected output"
                     "${(ps-custom
                           { dir = null; srcs = [ ./src ./src2 ];}
                        ).modules.Main.app { name = "test run"; }
                      }/bin/'test run' argument"
                     expected-output;

                 "no dir test" =
                   make-test "expected output"
                     "${(ps-custom
                           { dir = null; srcs = [ ./src ./src2 ]; test = ./test;}
                        ).test.run {}
                      }"
                     (i: "[[ ${i} == testing ]]");
               }
             // (with ps.modules.Main;
                 { "incremental output" = output { incremental = true; };

                   "incremental bundle" =
                     bundle { esbuild.platform = "node"; incremental = true; };

                   "incremental app" = app { name = "_"; incremental = true; };
                 }
                )
             // mapAttrs
                  (n:
                   { args ? {}
                   , less ? false
                   , ps' ? ps
                   , run-output ? expected-output
                   , test
                   }:
                     let
                       name = "test";

                       command =
                         ps'.command
                           (l.recursiveUpdate
                              { bundle.esbuild =
                                  { legal-comments = "none";
                                    platform = "node";
                                  };

                                compile.codegen = "docs,js";
                                inherit name package;
                              }
                              args
                           )
                         + "/bin/${name}";
                     in
                     p.stdenv.mkDerivation
                       { name = l.strings.sanitizeDerivationName n;
                         phases = [ "unpackPhase" "installPhase" "checkPhase" ];

                         src =
                           filterSource
                             (path: type:
                                (type == "directory"
                                 && any
                                      (s: (match ".*/${s}" path != null)
                                          || l.hasInfix "/${s}/" path
                                      )
                                      (args.srcs or [ "src" "src2" ]
                                       ++ [ (args.test or "test") ]
                                      )
                                )
                                || l.hasSuffix ".purs" path
                                || l.hasSuffix ".js" path
                             )
                             ./.;

                         buildInputs = [ p.nodejs ];
                         installPhase = "touch $out";
                         doCheck = true;

                         checkPhase =
                           (if less then
                              ""
                            else
                              make-test "purs-nix package-info prelude"
                                "${command} package-info prelude"
                                (i: ''
                                    info="name:    prelude
                                    version: override-test
                                    flake:   github:purs-nix/test-packages?dir=prelude&rev=debd6195fa1d1b2c15f244d496afe89414620a12
                                    package: default
                                    source:  /nix/store/4z6lgq2g8zr0k2h5sanm01hyl7a6b666-purs-nix.prelude-override-test"

                                    [[ ${i} == $info ]]
                                    ''
                                ) +

                              make-test "purs-nix package-info effect"
                                "${command} package-info effect"
                                (i: ''
                                    info="name:    effect
                                    version: override-test
                                    repo:    https://github.com/purs-nix/test-packages.git
                                    path:    /nix/store/ynjlvzkgnagj29kw1chi49pbfnx1kb19-1mayjlr32rmir706prrfgjx205357ycz-source
                                    source:  /nix/store/dhpfrhwy1ydwnzinrd61rrnyrjs5ai28-effect-override-test"

                                    [[ ${i} == $info ]]
                                    ''
                                ) +

                              make-test "purs-nix packages"
                                "${command} packages"
                                (i: ''
                                    packages="arraybuffer-types: 3.0.2
                                    arrays: 7.1.0
                                    assert: 6.0.0
                                    bifunctors: 6.0.0
                                    console: 6.0.0
                                    const: 6.0.0
                                    contravariant: 6.0.0
                                    control: 6.0.0
                                    distributive: 6.0.0
                                    effect: override-test
                                    either: 6.1.0
                                    exceptions: 6.0.0
                                    exists: 6.0.0
                                    foldable-traversable: 6.0.0
                                    foreign-object: 4.0.0
                                    functions: 6.0.0
                                    functors: 5.0.0
                                    gen: 4.0.0
                                    identity: 6.0.0
                                    invariant: 6.0.0
                                    lazy: 6.0.0
                                    lists: 7.0.0
                                    maybe: 6.0.0
                                    newtype: 5.0.0
                                    node-buffer: 8.0.0
                                    node-path: 5.0.0
                                    node-process: 10.0.0
                                    node-streams: 7.0.0
                                    nonempty: 7.0.0
                                    nullable: 6.0.0
                                    orders: 6.0.0
                                    partial: 4.0.0
                                    posix-types: 6.0.0
                                    prelude: override-test
                                    profunctor: 6.0.0
                                    purs-nix.build-test: 1.0.0
                                    purs-nix.is-even: 1.0.0
                                    purs-nix.is-odd: 1.0.0
                                    refs: 6.0.0
                                    safe-coerce: 2.0.0
                                    st: 6.2.0
                                    tailrec: 6.1.0
                                    tuples: 7.0.0
                                    type-equality: 4.0.1
                                    typelevel-prelude: 7.0.0
                                    unfoldable: 6.0.0
                                    unsafe-coerce: 6.0.0
                                    ursi.murmur3"

                                    [[ ${i} == $packages ]]
                                    ''
                                ) +

                              make-test "purs-nix bower"
                                ""
                                (_: "${command} bower") +

                              make-test "purs-nix test"
                                "${command} test"
                                (i: "[[ ${i} == testing ]]")
                           ) +

                           make-test "purs-nix bundle"
                             ""
                             (_: "${command} bundle") +

                           make-test "purs-nix run"
                             "${command} run argument"
                             run-output +

                           make-test "purs-nix docs"
                             ""
                             (_: "${command} docs") +

                           make-test "purs-nix docs --format markdown"
                             ""
                             (_: "${command} docs --format markdown") +

                           "\n" + test command + "\n" +

                           (if switches.repl then
                              let repl = "echo :q | HOME=. ${command} repl"; in
                              make-test "purs-nix repl"
                                ""
                                (_: repl) +

                              make-test "purs-nix repl: create .purs-repl"
                                "cat .purs-repl"
                                (i: ''[[ ${i} == "import Prelude" ]]'') +

                              make-test "purs-nix repl: don't override .purs-repl"
                                ""
                                (_: ''
                                    echo -- comment > .purs-repl
                                    ${repl}
                                    cat .purs-repl
                                    [[ $(cat .purs-repl) == "-- comment" ]]
                                    ''
                                )
                            else
                              ""
                           );
                       }
                  )
                  { "purs-nix command defaults" =
                      { test = command:
                          make-test "purs-nix srcs"
                            "${command} srcs"
                            (i: ''${purs-nix.purescript}/bin/purs compile ${i}'') +

                          make-test "main.js exists"
                            ""
                            (_: "ls main.js") +

                          "cp main.js 'test run'\n" +

                          make-test "running main.js is the same as purs-nix run"
                            "node 'test run'; ${command} run"
                            (_: ''
                                [[ "$(node 'test run')" \
                                == "$(${command} run)" \
                                ]]
                                ''
                            );
                      };

                    "purs-nix command configured" =
                      let
                        outfile = "outfile.js";
                        output = "compiled";
                      in
                      { args =
                          { inherit output;

                            bundle =
                              { esbuild =
                                  { external = [ 1 ''"2"'' "$three" "'4'" ];
                                    inherit outfile;
                                  };

                                module = "App";
                                main = false;
                              };
                          };

                        ps' =
                          ps-custom { test = "test-dir"; test-module = "Test.Test"; };

                        test = command:
                          make-test "list flags work"
                            "echo ${command}"
                            (_: ''cat ${command} | grep -- "--external:'1' --external:\"2\" --external:\$three --external:'4'"'') +

                          make-test "custom-named output exists"
                            ""
                            (_: "ls ${outfile}") +

                          make-test "bower.json is what we expect"
                            "diff bower.json ${./bower.json}"
                            (i: "[[ -z ${i} ]]") +

                          make-test "${outfile} does not call main"
                            "tail -n 1 ${outfile}"
                            (i: ''
                                # for some reason this doesn't fail if the file doesn't exists
                                [[ -e ${outfile} ]]
                                [[ ! ${i} == "main();" ]]
                                ''
                            ) +

                          make-test ''"output" does not exist''
                            "ls"
                            (_: "[[ ! -e output ]]");
                      };

                    "purs-nix command flake dependencies" =
                      { args =
                          { srcs = [ "src3" ];
                            test = "nonexistent";
                          };

                        less = true;
                        ps' = ps2;
                        run-output = i: "[[ ${i} == 1945310157 ]]";

                        test = command:
                          make-test "purs-nix package-info ursi.murmur3"
                            "${command} package-info ursi.murmur3"
                            (i: ''
                                info="name:    ursi.murmur3
                                version: none
                                flake:   github:ursi/purescript-murmur3/3aec0007073128b807a58adace08ee2b1197334b
                                package: default
                                source:  /nix/store/gb8qj76dpmy4cgb0zp6xmbn2ial1abxi-ursi.murmur3"

                                [[ ${i} == $info ]]
                                ''
                            );
                      };
                  }
                  // package-tests
                  // { "'check' api" = ps.test.check {}; };

           devShells.default =
             make-shell
               { packages =
                   with pkgs;
                   [ nodejs

                     (ps.command
                        { bundle.esbuild.platform = "node";
                          inherit package;
                          srcs = [ "src" "src2" ];
                        }
                     )

                     (ps2.command
                        { name = "ps2";
                          bundle.esbuild.platform = "node";
                          inherit package;
                          srcs = [ "src3" ];
                        }
                     )

                     ps-tools.for-0_15.purescript-language-server
                     purs-nix.esbuild
                     purs-nix.purescript
                   ];
               };
         }
      );
}
