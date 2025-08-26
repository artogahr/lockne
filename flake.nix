{
  description = "Lockne - Aya eBPF development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      rust = fenix.packages.${system}.stable;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        # ----------------------------------------------------------------
        # Packages added to PATH for interactive use in the dev shell
        # ----------------------------------------------------------------
        packages = [
          rust.toolchain
          pkgs.cargo-generate
          pkgs.bpftools
        ];

        # ----------------------------------------------------------------
        # Build-time dependencies (needed to compile)
        # ----------------------------------------------------------------
        nativeBuildInputs = [
          pkgs.llvmPackages.clang # Clang compiler
          pkgs.llvmPackages.libclang # LLVM C API libraries
          pkgs.pkg-config # Helps Rust crates find C libraries like OpenSSL
        ];

        # ----------------------------------------------------------------
        # Runtime dependencies (needed when running)
        # ----------------------------------------------------------------
        buildInputs = [
          pkgs.openssl
        ];
      };
    };
}
