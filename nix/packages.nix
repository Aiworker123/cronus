# nix/packages.nix — Cronus Agent package built with uv2nix
{ inputs, ... }:
{
  perSystem =
    { pkgs, lib, inputs', ... }:
    let
      cronusAgent = pkgs.callPackage ./cronus-agent.nix {
        inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
        npm-lockfile-fix = inputs'.npm-lockfile-fix.packages.default;
        # Only embed clean revs — dirtyRev doesn't represent any upstream
        # commit, so comparing it would always claim "update available".
        rev = inputs.self.rev or null;
      };
    in
    {
      packages = {
        default = cronusAgent;

        # Ships discord.py + python-telegram-bot + slack-sdk so a plain
        # `nix profile install .#messaging` connects to Discord/Telegram/Slack
        # on first run — lazy-install can't write to the read-only /nix/store.
        messaging = cronusAgent.override {
          extraDependencyGroups = [ "messaging" ];
        };

        # All platform-portable optional integrations pre-built.
        # matrix is Linux-only (oqs/liboqs lacks aarch64-darwin wheels).
        full = cronusAgent.override {
          extraDependencyGroups = [
            "anthropic"
            "azure-identity"
            "bedrock"
            "daytona"
            "dingtalk"
            "edge-tts"
            "exa"
            "fal"
            "feishu"
            "firecrawl"
            "hindsight"
            "honcho"
            "messaging"
            "modal"
            "parallel-web"
            "tts-premium"
            "vercel"
            "voice"
          ] ++ lib.optionals pkgs.stdenv.isLinux [ "matrix" ];
        };

        tui = cronusAgent.cronusTui;
        web = cronusAgent.cronusWeb;

        fix-lockfiles = cronusAgent.cronusNpmLib.mkFixLockfiles {
          packages = [ cronusAgent.cronusTui cronusAgent.cronusWeb ];
        };
      };
    };
}
