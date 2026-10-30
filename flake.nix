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
            git
            zls
            gradle
            jdk25
            (jdt-language-server.override { jdk = pkgs.jdk25; })
            jq
            curl
            xorg-server
            mesa
            libglvnd
          ];

          shellHook = ''
            # VS Code's Java extension and Gradle must use the same JDK as JDT LS.
            export JAVA_HOME="${pkgs.jdk25}/lib/openjdk"
            export JDK_HOME="$JAVA_HOME"
            if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ] && lightning_rod_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
              export ZIG_LOCAL_CACHE_DIR="$lightning_rod_root/.zig-cache"
            fi
            ulimit -S -l 32768 2>/dev/null || true
            export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri''${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"
            export LD_LIBRARY_PATH="${pkgs.mesa}/lib:${pkgs.libglvnd}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        };
      }
    );
}
