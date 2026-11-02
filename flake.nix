{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells."zig-0-16"
            ];

            # Project-specific tools.
            packages = with pkgs; [
              # The encoding_rs oracle (`just oracle`) and the Rust benchmark
              # arm; Cargo.lock pins the crates.
              cargo
              rustc
              rustfmt
              # The Go benchmark arm (golang.org/x/text, pinned by go.sum),
              # and benchstat from golang.org/x/perf.
              go
              goperf
              # The C benchmark arms: ICU, found with pkg-config, glibc's
              # iconv, and GNU libiconv.
              icu
              libiconvReal
              pkg-config
              # The web-platform-tests harness runs the package as
              # WebAssembly under Node.
              nodejs
              # `zig build test -fqemu` on a big-endian target (`just
              # test-big-endian`).
              qemu-user
              # The benchmarks: taskset pins every arm to one core, GNU time
              # gives each arm's peak RSS, curl fetches the corpus.
              util-linux
              time
              curl
            ];
          };
        };
    };
}
