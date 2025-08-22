{
  description = "Dev shell for Lockne (Rust + Aya)";

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
        packages = [
          rust.toolchain
          pkgs.openssl
          pkgs.pkg-config
          pkgs.cargo-generate
        ];
      };
    };
}
