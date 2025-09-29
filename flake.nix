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

      in
      {
        devShells.default = pkgs.mkShell {
          shell = pkgs.fish;

          buildInputs = [
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
        };
      }
    );
}
