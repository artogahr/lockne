{
  description = "Lockne - Aya eBPF development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fenix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        rust-toolchain = fenix.packages.${system}.fromToolchainFile {
          dir = ./code;
          sha256 = "sha256-tqagmXrHoZA9Zmu2Br6n3MzvXaLkuPzKPS3NIVdNQVQ=";
        };

        # Common build dependencies
        buildDeps = [
          rust-toolchain
          pkgs.rustup
          pkgs.cargo-generate
          pkgs.bpftools
          pkgs.bpf-linker
          pkgs.llvmPackages.clang
          pkgs.llvmPackages.libclang
          pkgs.pkg-config
          pkgs.zlib
          pkgs.elfutils
          pkgs.openssl
        ];

        # Benchmarking and testing tools
        benchDeps = [
          pkgs.iperf3
          pkgs.curl
          pkgs.wget
          pkgs.hyperfine      # Modern CLI benchmarking tool
          pkgs.proxychains-ng # For comparison benchmarks
          pkgs.wireguard-tools
          pkgs.tcpdump
          pkgs.iproute2
          pkgs.python3        # For benchmark scripts
          pkgs.gnuplot        # For generating graphs
        ];

      in
      {
        devShells = {
          default = pkgs.mkShell {
            buildInputs = buildDeps;
          };

          # Shell with benchmarking tools: nix develop .#bench
          bench = pkgs.mkShell {
            buildInputs = buildDeps ++ benchDeps;
            
            shellHook = ''
              echo "Lockne benchmark environment"
              echo "Available tools: iperf3, hyperfine, proxychains4, tcpdump, wg"
              echo ""
              echo "Run benchmarks: ./benchmarks/run_benchmarks.sh"
            '';
          };
        };
      }
    );
}
