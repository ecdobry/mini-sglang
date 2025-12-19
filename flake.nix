{
  description = "Mini-SGLang - A minimal implementation of SGLang";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Use Python 3.11 as specified in pyproject.toml
          python = pkgs.python311;
        in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              # Mark CUDA packages with RDMA dependencies as broken/optional
              (final: prev: {
                nvidia-cufile-cu12 = prev.nvidia-cufile-cu12.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [ "libmlx5.so.1" "librdmacm.so.1" "libibverbs.so.1" ];
                });
                nvidia-cusolver-cu12 = prev.nvidia-cusolver-cu12.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [ "libnvJitLink.so.12" "libcublas.so.12" "libcublasLt.so.12" "libcusparse.so.12" ];
                });
              })
            ]
          )
      );

    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system}.overrideScope editableOverlay;
          virtualenv = pythonSet.mkVirtualEnv "minisgl-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
              pkgs.git
            ];

            # System libraries needed for PyTorch and ML packages
            buildInputs = [
              pkgs.stdenv.cc.cc.lib
              pkgs.zlib
            ];

            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = pythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)

              # Set LD_LIBRARY_PATH for native dependencies
              export LD_LIBRARY_PATH="${lib.makeLibraryPath [
                pkgs.stdenv.cc.cc.lib
                pkgs.zlib
              ]}:$LD_LIBRARY_PATH"

              echo "Mini-SGLang development environment (pure Nix)"
              echo "Python: $(${pythonSet.python.interpreter} --version)"
              echo "uv: $(uv --version)"
              echo ""
              echo "Note: Using Nix-built Python packages. Some GPU packages may have limited functionality."
            '';
          };

          # Simpler impure shell using uv for package management
          impure = pkgs.mkShell {
            packages = [
              pkgs.python311
              pkgs.uv
              pkgs.git
            ];

            buildInputs = [
              pkgs.stdenv.cc.cc.lib
              pkgs.zlib
            ];

            shellHook = ''
              export LD_LIBRARY_PATH="${lib.makeLibraryPath [
                pkgs.stdenv.cc.cc.lib
                pkgs.zlib
              ]}:$LD_LIBRARY_PATH"

              echo "Mini-SGLang development environment (impure)"
              echo "Python: $(python --version)"
              echo "uv: $(uv --version)"
              echo ""
              echo "Run 'uv sync' to install dependencies"
              echo "Run 'source .venv/bin/activate' to activate the virtual environment"
            '';
          };
        }
      );

      packages = forAllSystems (system: {
        default = pythonSets.${system}.mkVirtualEnv "minisgl-env" workspace.deps.default;
      });
    };
}
