{
  inputs = {
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      # prevent nix-direnv from fetching stackage
      inputs.stackage.url = "github:input-output-hk/empty-flake";
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (inputs.haskellNix) config;
          overlays = [ inputs.haskellNix.overlay ];
        };
        inherit (pkgs) lib haskell-nix;
        inherit (haskell-nix) haskellLib;

        ghcVersions = [ "ghc965" "ghc982" "ghc9101" ];
        defaultGHCVersion = builtins.head ghcVersions;
        perGHC = lib.genAttrs ghcVersions (ghcVersion:
          let
            hsPkgs = pkgs.haskell-nix.cabalProject {
              src = ./.;
              compiler-nix-name = ghcVersion;
              modules = [{
                packages.fourmolu = {
                  writeHieFiles = true;
                  components.exes.fourmolu.preBuild =
                    lib.mkIf (self ? rev) ''export ORMOLU_REV=${self.rev}'';
                };
              }];
            };
            inherit (hsPkgs.fourmolu.components.exes) fourmolu;
            hackageTests = import ./expected-failures { inherit pkgs fourmolu; };
            regionTests = import ./region-tests { inherit pkgs fourmolu; };
            fixityTests = import ./fixity-tests { inherit pkgs fourmolu; };
            weeder = hsPkgs.tool "weeder" {
              version = "2.6.0";
              modules = [{ reinstallableLibGhc = false; }];
            };
            packages = lib.recurseIntoAttrs ({
              inherit fourmolu;
              ormoluTests = haskellLib.collectChecks' hsPkgs;
              dev = { inherit hsPkgs; };
            } // hackageTests // regionTests // fixityTests
            // lib.optionalAttrs (ghcVersion == defaultGHCVersion) {
              weeder = pkgs.runCommand "fourmolu-weeder" { buildInputs = [ weeder ]; } ''
                mkdir -p $out
                weeder --config ${./weeder.toml} \
                  --hie-directory ${hsPkgs.fourmolu.components.library.hie} \
                  --hie-directory ${hsPkgs.fourmolu.components.exes.fourmolu.hie} \
                  --hie-directory ${hsPkgs.fourmolu.components.tests.tests.hie} \
              '';
            });
          in
          packages // {
            ci = pkgs.linkFarm "ormolu-ci-${ghcVersion}"
              (flake-utils.lib.flattenTree packages);
          });
        defaultGHC = perGHC.${defaultGHCVersion};

        binaries =
          let
            hsPkgs = defaultGHC.dev.hsPkgs.appendModule {
              modules = [{
                dontStrip = false;
                dontPatchELF = false;
                enableDeadCodeElimination = true;
              }];
            };
            fourmoluExe = hsPkgs: hsPkgs.hsPkgs.fourmolu.components.exes.fourmolu;
            linuxWindows = {
              native = fourmoluExe hsPkgs.projectCross.musl64;
              windows = fourmoluExe hsPkgs.projectCross.mingwW64;
            };
            macOS.native = pkgs.runCommand "fourmolu-macOS"
              {
                nativeBuildInputs = [
                  pkgs.macdylibbundler
                  pkgs.darwin.autoSignDarwinBinariesHook
                ];
              } ''
              mkdir -p $out/bin
              cp ${fourmoluExe hsPkgs}/bin/fourmolu $out/bin/fourmolu
              chmod 755 $out/bin/fourmolu
              dylibbundler -b --no-codesign \
                -x $out/bin/fourmolu \
                -d $out/bin \
                -p '@executable_path'
              signDarwinBinariesInAllOutputs
            '';
          in
          lib.recurseIntoAttrs
            (lib.optionalAttrs (system == "x86_64-linux") linuxWindows
              // lib.optionalAttrs pkgs.hostPlatform.isDarwin macOS);
      in
      {
        packages = flake-utils.lib.flattenTree {
          inherit binaries;
          default = defaultGHC.fourmolu;
        };
        apps.default = flake-utils.lib.mkApp {
          drv = defaultGHC.fourmolu;
          exePath = "/bin/fourmolu";
        };
        devShells = {
          default = defaultGHC.dev.hsPkgs.shellFor {
            tools = {
              cabal = "latest";
              haskell-language-server = {
                src = inputs.haskellNix.inputs."hls-2.8";
                configureArgs = "--disable-benchmarks --disable-tests";
              };
            };
            withHoogle = false;
            exactDeps = false;
          };
        };
        legacyPackages = defaultGHC // perGHC;
      });
  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://cache.zw3rk.com"
      "https://tweag-ormolu.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
      "tweag-ormolu.cachix.org-1:3O4XG3o4AGquSwzzmhF6lov58PYG6j9zHcTDiROqkjM="
    ];
  };
}
