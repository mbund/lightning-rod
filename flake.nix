{
  description = "Lightning Rod";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          name = "lightning-rod";

          buildInputs = with pkgs; [
            zig
            zls
            openssl
            gradle
            jdk21
            jq
            curl
            xorg-server
            mesa
            libglvnd
          ];

          shellHook = ''
            ulimit -S -l 32768 2>/dev/null || true
            export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri''${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"
            export LD_LIBRARY_PATH="${pkgs.mesa}/lib:${pkgs.libglvnd}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        };
      }
    );
}
