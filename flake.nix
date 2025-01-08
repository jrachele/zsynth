{
  description = "ZSynth nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, zig-overlay, flake-utils, zls }:
  flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = zig-overlay.packages.${system}.master;
          # zls = zls.packages.${system}.default;
        in
              rec {
                formatter = pkgs.nixpkgs-fmt;
                packages.default = pkgs.stdenv.mkDerivation {
                  name = "zsynth";
                  src = ./.;
                  nativeBuildInputs = [ zig ];
                  buildPhase = ''
                    zig build
                  '';
                };
                devShells.default = pkgs.mkShell {
                    buildInputs = [
                    zig
                    zls.packages.${system}.zls
                    ];
                };
               }
    );
}
