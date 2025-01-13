#
# Copyright 2024, UNSW
# SPDX-License-Identifier: BSD-2-Clause
#
{
  description = "A flake for building sDDF";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/24.05";
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

        zig = zig-overlay.packages.${system}.master;

        pysdfgen = with pkgs.python312Packages;
          buildPythonPackage rec {
            pname = "sdfgen";
            version = "0.2.0";
            # TODO: fix this
            src = ./.;

            build-system = [ setuptools ];

            meta = with lib; {
              homepage = "https://github.com/au-ts/microkit_sdf_gen";
              maintainers = with maintainers; [ au-ts ];
            };

            preBuild = ''
              export ZIG_LOCAL_CACHE_DIR=$(mktemp -d)
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            '';

            nativeBuildInputs = [ zig ];
          };
      in
      {
        devShells.default = pkgs.mkShell rec {
          name = "dev";

          nativeBuildInputs = with pkgs; [
            dtc
            zig
            python313
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
