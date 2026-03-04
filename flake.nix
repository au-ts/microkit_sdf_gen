#
# Copyright 2024, UNSW
# SPDX-License-Identifier: BSD-2-Clause
#
{
  description = "A flake for building sdfgen";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig-overlay, ... }@inputs: inputs.utils.lib.eachSystem [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ]
    (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        zig = zig-overlay.packages.${system}."0.15.1";

        pysdfgen = pkgs.callPackage ./package.nix { zig = zig; pythonPackages = pkgs.python312Packages; };
      in
      {
        devShells.default = pkgs.mkShell rec {
          name = "dev";

          nativeBuildInputs = with pkgs; [
            dtc
            zig
            python312
            sphinx
          ];
        };

        devShells.ci = pkgs.mkShell rec {
          name = "ci";

          pythonWithSdfgen = pkgs.python312.withPackages (ps: [
            pysdfgen
            ps.sphinx-rtd-theme
          ]);

          nativeBuildInputs = with pkgs; [
            dtc
            zig
            pythonWithSdfgen
            sphinx
          ];
        };

        packages.pysdfgen = pysdfgen;
      });
}
