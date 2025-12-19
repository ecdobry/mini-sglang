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

      # Create a pkgs instance that allows unfree packages (for CUDA)
      pkgsFor = system: import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          cudaSupport = true;
        };
      };

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
          pkgs = pkgsFor system;
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
                nvidia-cusparse-cu12 = prev.nvidia-cusparse-cu12.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [ "libnvJitLink.so.12" ];
                });
                nvidia-cutlass-dsl = prev.nvidia-cutlass-dsl.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];
                });
                nvidia-nvshmem-cu12 = prev.nvidia-nvshmem-cu12.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [
                    "libucs.so.0" "libucp.so.0"  # UCX dependencies
                    "liboshmem.so.40"            # OpenSHMEM
                    "libmlx5.so.1"               # Mellanox InfiniBand
                    "libmpi.so.40"               # MPI
                    "libpmix.so.2"               # PMIx
                    "libfabric.so.1"             # libfabric
                  ];
                });
                sgl-kernel = prev.sgl-kernel.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [
                    # CUDA runtime libraries
                    "libcuda.so.1" "libcudart.so.12" "libnvrtc.so.12"
                    "libcublas.so.12" "libcublasLt.so.12"
                    # PyTorch libraries
                    "libtorch.so" "libtorch_cpu.so" "libtorch_cuda.so"
                    "libc10.so" "libc10_cuda.so"
                    # System libraries
                    "libnuma.so.1"
                  ];
                });
                torch = prev.torch.overrideAttrs (old: {
                  autoPatchelfIgnoreMissingDeps = [
                    # CUDA driver/runtime
                    "libcuda.so.1" "libcudart.so.12" "libnvrtc.so.12"
                    # cuBLAS
                    "libcublas.so.12" "libcublasLt.so.12"
                    # cuDNN
                    "libcudnn.so.9"
                    # cuSPARSE and cuSPARSELt
                    "libcusparse.so.12" "libcusparseLt.so.0"
                    # cuSOLVER
                    "libcusolver.so.11"
                    # cuFFT
                    "libcufft.so.11"
                    # cuRAND
                    "libcurand.so.10"
                    # cuFile (GPU Direct Storage)
                    "libcufile.so.0"
                    # NCCL
                    "libnccl.so.2"
                    # CUPTI (profiling)
                    "libcupti.so.12"
                    # NVSHMEM
                    "libnvshmem_host.so.3"
                  ];
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
          pkgs = pkgsFor system;
          pythonSet = pythonSets.${system}.overrideScope editableOverlay;
          virtualenv = pythonSet.mkVirtualEnv "minisgl-dev-env" workspace.deps.all;
        in
        {
          default =
            let
              cudaPackages = pkgs.cudaPackages;
              # Create a merged CUDA toolkit directory for tools that expect a single CUDA_HOME
              cudaToolkit = pkgs.symlinkJoin {
                name = "cuda-toolkit-merged";
                paths = with cudaPackages; [
                  cuda_nvcc
                  cuda_cudart          # only has 'out' (includes headers)
                  cuda_cccl
                  cuda_cupti
                  cuda_cupti.lib
                  cuda_cupti.include
                  libcublas
                  libcublas.lib
                  libcublas.include
                  libcusparse
                  libcusparse.lib
                  libcusparse.include
                  libcusparse_lt
                  libcusparse_lt.lib
                  libcusparse_lt.include
                  libcusolver
                  libcusolver.lib
                  libcusolver.include
                  libcufft
                  libcufft.lib
                  libcufft.include
                  libcurand
                  libcurand.lib
                  libcurand.include
                  libcufile
                  libcufile.lib
                  libcufile.include
                  libnvjitlink
                  libnvjitlink.include
                  cudnn
                  cudnn.lib
                  cudnn.include
                  nccl
                  nccl.dev             # nccl uses 'dev' for headers, not 'include'
                ];
              };
            in
            pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
              pkgs.git
              pkgs.ninja  # Required for FlashInfer JIT compilation
            ] ++ lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") [
              cudaToolkit
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
            } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
              CUDA_HOME = cudaToolkit;
              CUDA_PATH = cudaToolkit;
            };

            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)

              # Get the Python site-packages directory
              SITE_PACKAGES=$(python -c "import site; print(site.getsitepackages()[0])")

              # Add NVIDIA Python package libraries to LD_LIBRARY_PATH
              # These contain the correctly versioned CUDA libraries that PyTorch expects
              for nvidia_pkg in nvidia/cublas nvidia/cuda_cupti nvidia/cuda_nvrtc nvidia/cuda_runtime \
                               nvidia/cudnn nvidia/cufft nvidia/curand nvidia/cusolver nvidia/cusparse \
                               nvidia/nccl nvidia/nvjitlink nvidia/nvshmem; do
                if [ -d "$SITE_PACKAGES/$nvidia_pkg/lib" ]; then
                  export LD_LIBRARY_PATH="$SITE_PACKAGES/$nvidia_pkg/lib:$LD_LIBRARY_PATH"
                fi
              done

              # Add torch lib directory
              if [ -d "$SITE_PACKAGES/torch/lib" ]; then
                export LD_LIBRARY_PATH="$SITE_PACKAGES/torch/lib:$LD_LIBRARY_PATH"
              fi

              # Set LD_LIBRARY_PATH for native dependencies and CUDA toolkit (for JIT compilation)
              export LD_LIBRARY_PATH="${cudaToolkit}/lib:${lib.makeLibraryPath [
                pkgs.stdenv.cc.cc.lib
                pkgs.zlib
              ]}:$LD_LIBRARY_PATH"

              # Set LIBRARY_PATH for linker to find CUDA libraries during JIT compilation
              export LIBRARY_PATH="${cudaToolkit}/lib:$LIBRARY_PATH"

              # Add NVIDIA driver libraries for CUDA support (libcuda.so.1)
              # NixOS standard location
              if [ -d "/run/opengl-driver/lib" ]; then
                export LD_LIBRARY_PATH="/run/opengl-driver/lib:$LD_LIBRARY_PATH"
                # LIBRARY_PATH is needed for linker to find libcuda during JIT compilation (e.g., FlashInfer)
                export LIBRARY_PATH="/run/opengl-driver/lib:$LIBRARY_PATH"
              fi

              echo "Mini-SGLang development environment (pure Nix)"
              echo "Python: $(${pythonSet.python.interpreter} --version)"
              echo "uv: $(uv --version)"
              echo ""
              if python -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
                echo "CUDA: Available ($(python -c 'import torch; print(torch.version.cuda)'))"
                echo "CUDA_HOME: $CUDA_HOME"
              else
                echo "CUDA: Not available (check NVIDIA drivers)"
              fi
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
