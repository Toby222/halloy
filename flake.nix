{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      pre-commit-hooks,
      rust-overlay,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f rec {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ (import rust-overlay) ];
            };

            rustToolchainFor = pkgs: pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
            rustToolchain = rustToolchainFor pkgs;

            # NB: we don't need to overlay our custom toolchain for the *entire*
            # pkgs (which would require rebuidling anything else which uses rust).
            # Instead, we just want to update the scope that crane will use by appending
            # our specific toolchain there.
            craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchainFor;
          }
        );
    in
    {
      formatter = forEachSupportedSystem (
        { pkgs, ... }: pkgs.writeShellScriptBin "format" "${pkgs.pre-commit}/bin/pre-commit"
      );
      checks = forEachSupportedSystem (
        { pkgs, craneLib, ... }:
        {
          pre-commit-check = pre-commit-hooks.lib.${pkgs.system}.run {
            src = ./.;
            # See all at https://devenv.sh/reference/options/#git-hookshooks
            hooks = {
              nixfmt-rfc-style.enable = true;
              clippy = {
                enable = true;
                packageOverrides = {
                  cargo = craneLib.cargo;
                  clippy = craneLib.clippy;
                };
              };
              rustfmt = {
                enable = true;
                packageOverrides = {
                  cargo = craneLib.cargo;
                  rustfmt = craneLib.rustfmt;
                };
              };
            };
          };
        }
      );
      devShells = forEachSupportedSystem (
        { pkgs, rustToolchain, ... }:
        {
          default = pkgs.mkShell rec {
            inherit (self.checks.${pkgs.system}.pre-commit-check) shellHook;
            packages =
              (self.checks.${pkgs.system}.pre-commit-check.enabledPackages)
              ++ (with pkgs; [
                nixd
                rustToolchain

                pkg-config
                alsa-lib
                libGL
                libGLU
                libxkbcommon
                openssl
                shaderc.lib
                vulkan-loader
                wayland
                xorg.libX11
                xorg.libxcb
                xorg.libXcursor
              ]);
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath packages;
          };
        }
      );
      packages = forEachSupportedSystem (
        {
          pkgs,
          rustToolchain,
          craneLib,
          ...
        }:
        {
          default = (
            let
              manifest = (pkgs.lib.importTOML ./Cargo.toml).package;
              rustToolchainSettings = (pkgs.lib.importTOML ./rust-toolchain.toml).toolchain;
              src = craneLib.cleanCargoSource ./.;
            in
            craneLib.buildPackage {
              pname = manifest.name;
              version = manifest.version;
              inherit src;
              strictDeps = true;

              cargoVendorDir = craneLib.vendorMultipleCargoDeps {
                inherit (craneLib.findCargoFiles src) cargoConfigs;
                cargoLockList = [
                  ./Cargo.lock

                  # Unfortunately this approach requires IFD (import-from-derivation)
                  # otherwise Nix will refuse to read the Cargo.lock from our toolchain
                  # (unless we build with `--impure`).
                  #
                  # Another way around this is to manually copy the rustlib `Cargo.lock`
                  # to the repo and import it with `./path/to/rustlib/Cargo.lock` which
                  # will avoid IFD entirely but will require manually keeping the file
                  # up to date!
                  "${rustToolchain.passthru.availableComponents.rust-src}/lib/rustlib/src/rust/library/Cargo.lock"
                ];
              };

              cargoExtraArgs =
                if rustToolchainSettings.channel == "nightly" then "-Z build-std=std,core,alloc" else "";

              buildInputs = [
                # Add additional build inputs here
              ];
            }
          );
        }
      );

      overlays.default = final: prev: {
        rust-nix-template = self.packages.${final.system}.default;
      };
      nixosModules.rust-nix-template =
        { ... }:
        {
          nixpkgs.overlays = [ self.overlay ];
        };
    };
}
