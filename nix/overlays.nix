# nix/overlays.nix — Expose pkgs.cronus-agent for external NixOS configs
{ inputs, ... }:
{
  flake.overlays.default = final: _: {
    cronus-agent = final.callPackage ./cronus-agent.nix {
      inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
      npm-lockfile-fix = inputs.npm-lockfile-fix.packages.${final.stdenv.hostPlatform.system}.default;
      rev = inputs.self.rev or null;
    };
  };
}
