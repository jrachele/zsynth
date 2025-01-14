{
  description = "ZSynth nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zig-language-server.url = "github:zigtools/zls";
    zig-language-server.inputs.nixpkgs.follows = "nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , zig-overlay
    , flake-utils
    , zig-language-server
    ,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}.master;
        zls = zig-language-server.packages.${system}.zls;
      in
      {
        formatter = pkgs.nixpkgs-fmt;
        packages.default = pkgs.stdenv.mkDerivation {
          name = "zsynth";
          src = ./.;
          nativeBuildInputs = [ zig ];
          buildInputs = with pkgs; [ wayland ];
          buildPhase = ''
            zig build
          '';
        };
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            zig
            zls
          ];

          packages = with pkgs;[
            wayland
            glfw-wayland
            xorg.libX11
          ];

          env.LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
            wayland
            glfw-wayland
            libxkbcommon
            xorg.libX11
          ]);
        };
      }
    );
}
