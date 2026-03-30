{
  description = "Sign and push Nix store paths to an S3-compatible binary cache";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.writeShellApplication {
            name = "nix-cache-push";
            runtimeInputs = with pkgs; [
              coreutils
              jq
            ];
            text = builtins.replaceStrings [ "@fallbackNix@" ] [ "${pkgs.nix}/bin/nix" ] (
              builtins.readFile ./bin/nix-cache-push.sh
            );
            meta = {
              description = "Sign and push Nix store paths to an S3-compatible binary cache";
              mainProgram = "nix-cache-push";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/nix-cache-push";
        };
      });
    };
}
