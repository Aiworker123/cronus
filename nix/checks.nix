# nix/checks.nix — Build-time verification tests
#
# Checks are Linux-only: the full Python venv (via uv2nix) includes
# transitive deps like onnxruntime that lack compatible wheels on
# aarch64-darwin. The package and devShell still work on macOS.
{ inputs, ... }: {
  perSystem = { pkgs, lib, self', ... }:
    let
      cronus-agent = self'.packages.default;
      cronusVenv = cronus-agent.cronusVenv;

      configMergeScript = pkgs.callPackage ./configMergeScript.nix { };

      # Auto-generated config key reference — always in sync with Python
      configKeys = pkgs.runCommand "cronus-config-keys" {} ''
        set -euo pipefail
        export HOME=$TMPDIR
        ${cronusVenv}/bin/python3 -c '
import json, sys
from cronus_cli.config import DEFAULT_CONFIG

def leaf_paths(d, prefix=""):
    paths = []
    for k, v in sorted(d.items()):
        path = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict) and v:
            paths.extend(leaf_paths(v, path))
        else:
            paths.append(path)
    return paths

json.dump(sorted(leaf_paths(DEFAULT_CONFIG)), sys.stdout, indent=2)
' > $out
      '';
    in {
      packages.configKeys = configKeys;

      checks = {
        # Cross-platform evaluation — catches "not supported for interpreter"
        # errors (e.g. sphinx dropping python311) without needing a darwin builder.
        # Evaluation is pure and instant; it doesn't build anything.
        cross-eval = let
          targetSystems = builtins.filter
            (s: inputs.self.packages ? ${s})
            [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
          tryEvalPkg = sys:
            let pkg = inputs.self.packages.${sys}.default;
            in builtins.tryEval (builtins.seq pkg.drvPath true);
          results = map (sys: { inherit sys; result = tryEvalPkg sys; }) targetSystems;
          failures = builtins.filter (r: !r.result.success) results;
          failMsg = lib.concatMapStringsSep "\n" (r: "  - ${r.sys}") failures;
        in pkgs.runCommand "cronus-cross-eval" { } (
          if failures != [] then
            throw "Package fails to evaluate on:\n${failMsg}"
          else ''
            echo "PASS: package evaluates on all ${toString (builtins.length targetSystems)} platforms"
            mkdir -p $out
            echo "ok" > $out/result
          ''
        );
      } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # Verify binaries exist and are executable
        package-contents = pkgs.runCommand "cronus-package-contents" { } ''
          set -e
          echo "=== Checking binaries ==="
          test -x ${cronus-agent}/bin/cronus || (echo "FAIL: cronus binary missing"; exit 1)
          test -x ${cronus-agent}/bin/cronus-agent || (echo "FAIL: cronus-agent binary missing"; exit 1)
          echo "PASS: All binaries present"

          echo "=== Checking version ==="
          ${cronus-agent}/bin/cronus version 2>&1 | grep -qi "cronus" || (echo "FAIL: version check"; exit 1)
          echo "PASS: Version check"

          echo "=== All checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify every pyproject.toml [project.scripts] entry has a wrapped binary
        entry-points-sync = pkgs.runCommand "cronus-entry-points-sync" { } ''
          set -e
          echo "=== Checking entry points match pyproject.toml [project.scripts] ==="
          for bin in cronus cronus-agent cronus-acp; do
            test -x ${cronus-agent}/bin/$bin || (echo "FAIL: $bin binary missing from Nix package"; exit 1)
            echo "PASS: $bin present"
          done

          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify CLI subcommands are accessible
        cli-commands = pkgs.runCommand "cronus-cli-commands" { } ''
          set -e
          export HOME=$(mktemp -d)

          echo "=== Checking cronus --help ==="
          ${cronus-agent}/bin/cronus --help 2>&1 | grep -q "gateway" || (echo "FAIL: gateway subcommand missing"; exit 1)
          ${cronus-agent}/bin/cronus --help 2>&1 | grep -q "config" || (echo "FAIL: config subcommand missing"; exit 1)
          echo "PASS: All subcommands accessible"

          echo "=== All CLI checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify bundled skills are present in the package
        bundled-skills = pkgs.runCommand "cronus-bundled-skills" { } ''
          set -e
          echo "=== Checking bundled skills ==="
          test -d ${cronus-agent}/share/cronus-agent/skills || (echo "FAIL: skills directory missing"; exit 1)
          echo "PASS: skills directory exists"

          SKILL_COUNT=$(find ${cronus-agent}/share/cronus-agent/skills -name "SKILL.md" | wc -l)
          test "$SKILL_COUNT" -gt 0 || (echo "FAIL: no SKILL.md files found in skills directory"; exit 1)
          echo "PASS: $SKILL_COUNT bundled skills found"

          grep -q "CRONUS_BUNDLED_SKILLS" ${cronus-agent}/bin/cronus || \
            (echo "FAIL: CRONUS_BUNDLED_SKILLS not in wrapper"; exit 1)
          echo "PASS: CRONUS_BUNDLED_SKILLS set in wrapper"

          echo "=== All bundled skills checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify bundled plugins (platforms, memory, context_engine) are present
        bundled-plugins = pkgs.runCommand "cronus-bundled-plugins" { } ''
          set -e
          echo "=== Checking bundled plugins ==="
          test -d ${cronus-agent}/share/cronus-agent/plugins || (echo "FAIL: plugins directory missing"; exit 1)
          echo "PASS: plugins directory exists"

          test -f ${cronus-agent}/share/cronus-agent/plugins/platforms/irc/plugin.yaml || \
            (echo "FAIL: irc plugin manifest missing"; exit 1)
          echo "PASS: irc plugin manifest present"

          grep -q "CRONUS_BUNDLED_PLUGINS" ${cronus-agent}/bin/cronus || \
            (echo "FAIL: CRONUS_BUNDLED_PLUGINS not in wrapper"; exit 1)
          echo "PASS: CRONUS_BUNDLED_PLUGINS set in wrapper"

          echo "=== All bundled plugins checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify bundled TUI is present and compiled
        bundled-tui = pkgs.runCommand "cronus-bundled-tui" { } ''
          set -e
          echo "=== Checking bundled TUI ==="
          test -d ${cronus-agent}/ui-tui || (echo "FAIL: ui-tui directory missing"; exit 1)
          echo "PASS: ui-tui directory exists"

          test -f ${cronus-agent}/ui-tui/dist/entry.js || (echo "FAIL: compiled entry.js missing"; exit 1)
          echo "PASS: compiled entry.js present"

          # self-contained bundle; no runtime node_modules expected

          grep -q "CRONUS_TUI_DIR" ${cronus-agent}/bin/cronus || \
            (echo "FAIL: CRONUS_TUI_DIR not in wrapper"; exit 1)
          echo "PASS: CRONUS_TUI_DIR set in wrapper"

          echo "=== All bundled TUI checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify CRONUS_NODE is set in wrapper and points to Node 20+
        # (string-width uses the /v regex flag which requires Node 20+)
        cronus-node = pkgs.runCommand "cronus-node-version" { } ''
          set -e
          echo "=== Checking CRONUS_NODE in wrapper ==="
          grep -q "CRONUS_NODE" ${cronus-agent}/bin/cronus || \
            (echo "FAIL: CRONUS_NODE not set in wrapper"; exit 1)
          echo "PASS: CRONUS_NODE present in wrapper"

          CRONUS_NODE=$(sed -n "s/^export CRONUS_NODE='\(.*\)'/\1/p" ${cronus-agent}/bin/cronus)
          test -x "$CRONUS_NODE" || (echo "FAIL: CRONUS_NODE=$CRONUS_NODE not executable"; exit 1)
          echo "PASS: CRONUS_NODE executable at $CRONUS_NODE"

          NODE_MAJOR=$("$CRONUS_NODE" --version | sed 's/^v//' | cut -d. -f1)
          test "$NODE_MAJOR" -ge 20 || \
            (echo "FAIL: Node v$NODE_MAJOR < 20, TUI needs /v regex flag support"; exit 1)
          echo "PASS: Node v$NODE_MAJOR >= 20"

          echo "=== All CRONUS_NODE checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify CRONUS_MANAGED guard works on all mutation commands
        managed-guard = pkgs.runCommand "cronus-managed-guard" { } ''
          set -e
          export HOME=$(mktemp -d)

          check_blocked() {
            local label="$1"
            shift
            OUTPUT=$(CRONUS_MANAGED=true "$@" 2>&1 || true)
            echo "$OUTPUT" | grep -q "managed by NixOS" || (echo "FAIL: $label not guarded"; echo "$OUTPUT"; exit 1)
            echo "PASS: $label blocked in managed mode"
          }

          echo "=== Checking CRONUS_MANAGED guards ==="
          check_blocked "config set" ${cronus-agent}/bin/cronus config set model foo
          check_blocked "config edit" ${cronus-agent}/bin/cronus config edit

          echo "=== All guard checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify extraPythonPackages PYTHONPATH injection
        extra-python-packages = let
          testPkg = pkgs.python312Packages.pyfiglet;
          cronusWithExtra = cronus-agent.override {
            extraPythonPackages = [ testPkg ];
          };
        in pkgs.runCommand "cronus-extra-python-packages" { } ''
          set -e
          echo "=== Checking extraPythonPackages PYTHONPATH injection ==="

          grep -q "PYTHONPATH" ${cronusWithExtra}/bin/cronus || \
            (echo "FAIL: PYTHONPATH not in wrapper"; exit 1)
          echo "PASS: PYTHONPATH present in wrapper"

          grep -q "${testPkg}" ${cronusWithExtra}/bin/cronus || \
            (echo "FAIL: test package path not in PYTHONPATH"; exit 1)
          echo "PASS: test package path found in wrapper"

          echo "=== Checking base package has no PYTHONPATH ==="
          if grep -q "PYTHONPATH" ${cronus-agent}/bin/cronus; then
            echo "FAIL: base package should not have PYTHONPATH"; exit 1
          fi
          echo "PASS: base package clean"

          echo "=== All extraPythonPackages checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Verify extraDependencyGroups passes through to python.nix
        extra-dependency-groups = let
          cronusWithGroups = cronus-agent.override {
            extraDependencyGroups = [ "honcho" ];
          };
        in pkgs.runCommand "cronus-extra-dependency-groups" { } ''
          set -e
          echo "=== Checking extraDependencyGroups override evaluates ==="

          # Eval-only: verify the override produces valid derivation paths
          # without building the full venv (which is expensive and redundant
          # since the mechanism is just list concatenation into python.nix).
          echo "derivation: ${cronusWithGroups}"
          echo "venv: ${cronusWithGroups.cronusVenv}"
          echo "PASS: extraDependencyGroups override evaluates cleanly"

          echo "=== All extraDependencyGroups checks passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # Regression guard: messaging deps live outside [all], so the
        # #messaging variant must actually ship discord.py — otherwise
        # `nix profile install .#messaging` regresses to the broken default.
        messaging-variant = pkgs.runCommand "cronus-messaging-variant" { } ''
          set -e
          echo "=== Checking discord.py importable from messaging variant ==="
          ${self'.packages.messaging.cronusVenv}/bin/python3 -c \
            "import discord; print(discord.__version__)"
          echo "PASS: discord.py importable from messaging variant venv"
          mkdir -p $out
          echo "ok" > $out/result
        '';

        # ── Config merge + round-trip test ────────────────────────────────
        # Tests the merge script (Nix activation behavior) across 7
        # scenarios, then verifies Python's load_config() reads correctly.
        config-roundtrip = let
          # Nix settings used across scenarios
          nixSettings = pkgs.writeText "nix-settings.json" (builtins.toJSON {
            model = "test/nix-model";
            toolsets = ["nix-toolset"];
            terminal = { backend = "docker"; timeout = 999; };
            mcp_servers = {
              nix-server = { command = "echo"; args = ["nix"]; };
            };
          });

          # Pre-built YAML fixtures for each scenario
          fixtureB = pkgs.writeText "fixture-b.yaml" ''
            model: "old-model"
            mcp_servers:
              old-server:
                url: "http://old"
          '';
          fixtureC = pkgs.writeText "fixture-c.yaml" ''
            skills:
              disabled:
                - skill-a
                - skill-b
            session_reset:
              mode: idle
              idle_minutes: 30
            streaming:
              enabled: true
            fallback_model:
              provider: openrouter
              model: test-fallback
          '';
          fixtureD = pkgs.writeText "fixture-d.yaml" ''
            model: "user-model"
            skills:
              disabled:
                - skill-x
            streaming:
              enabled: true
              transport: edit
          '';
          fixtureE = pkgs.writeText "fixture-e.yaml" ''
            mcp_servers:
              user-server:
                url: "http://user-mcp"
              nix-server:
                command: "old-cmd"
                args: ["old"]
          '';
          fixtureF = pkgs.writeText "fixture-f.yaml" ''
            terminal:
              cwd: "/user/path"
              custom_key: "preserved"
              env_passthrough:
                - USER_VAR
          '';

        in pkgs.runCommand "cronus-config-roundtrip" {
          nativeBuildInputs = [ pkgs.jq ];
        } ''
          set -e
          export HOME=$(mktemp -d)
          ERRORS=""

          fail() { ERRORS="$ERRORS\nFAIL: $1"; }

          # Helper: run merge then load with Python, output merged JSON
          merge_and_load() {
            local cronus_home="$1"
            export CRONUS_HOME="$cronus_home"
            ${configMergeScript} ${nixSettings} "$cronus_home/config.yaml"
            ${cronusVenv}/bin/python3 -c '
import json, sys
from cronus_cli.config import load_config
json.dump(load_config(), sys.stdout, default=str)
'
          }

          # ═══════════════════════════════════════════════════════════════
          # Scenario A: Fresh install — no existing config.yaml
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario A: Fresh install ==="
          A_HOME=$(mktemp -d)
          A_CONFIG=$(merge_and_load "$A_HOME")

          echo "$A_CONFIG" | jq -e '.model == "test/nix-model"' > /dev/null \
            || fail "A: model not set from Nix"
          echo "$A_CONFIG" | jq -e '.mcp_servers."nix-server".command == "echo"' > /dev/null \
            || fail "A: MCP nix-server missing"
          echo "PASS: Scenario A"

          # ═══════════════════════════════════════════════════════════════
          # Scenario B: Nix keys override existing values
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario B: Nix overrides ==="
          B_HOME=$(mktemp -d)
          install -m 0644 ${fixtureB} "$B_HOME/config.yaml"
          B_CONFIG=$(merge_and_load "$B_HOME")

          echo "$B_CONFIG" | jq -e '.model == "test/nix-model"' > /dev/null \
            || fail "B: Nix model did not override"
          echo "PASS: Scenario B"

          # ═══════════════════════════════════════════════════════════════
          # Scenario C: User-only keys preserved
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario C: User keys preserved ==="
          C_HOME=$(mktemp -d)
          install -m 0644 ${fixtureC} "$C_HOME/config.yaml"
          C_CONFIG=$(merge_and_load "$C_HOME")

          echo "$C_CONFIG" | jq -e '.skills.disabled == ["skill-a", "skill-b"]' > /dev/null \
            || fail "C: skills.disabled not preserved"
          echo "$C_CONFIG" | jq -e '.session_reset.mode == "idle"' > /dev/null \
            || fail "C: session_reset.mode not preserved"
          echo "$C_CONFIG" | jq -e '.session_reset.idle_minutes == 30' > /dev/null \
            || fail "C: session_reset.idle_minutes not preserved"
          echo "$C_CONFIG" | jq -e '.streaming.enabled == true' > /dev/null \
            || fail "C: streaming.enabled not preserved"
          echo "$C_CONFIG" | jq -e '.fallback_model.provider == "openrouter"' > /dev/null \
            || fail "C: fallback_model not preserved"
          echo "PASS: Scenario C"

          # ═══════════════════════════════════════════════════════════════
          # Scenario D: Mixed — Nix wins for its keys, user keys preserved
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario D: Mixed merge ==="
          D_HOME=$(mktemp -d)
          install -m 0644 ${fixtureD} "$D_HOME/config.yaml"
          D_CONFIG=$(merge_and_load "$D_HOME")

          echo "$D_CONFIG" | jq -e '.model == "test/nix-model"' > /dev/null \
            || fail "D: Nix model did not override user model"
          echo "$D_CONFIG" | jq -e '.skills.disabled == ["skill-x"]' > /dev/null \
            || fail "D: user skills not preserved"
          echo "$D_CONFIG" | jq -e '.streaming.enabled == true' > /dev/null \
            || fail "D: user streaming not preserved"
          echo "PASS: Scenario D"

          # ═══════════════════════════════════════════════════════════════
          # Scenario E: MCP additive merge
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario E: MCP additive merge ==="
          E_HOME=$(mktemp -d)
          install -m 0644 ${fixtureE} "$E_HOME/config.yaml"
          E_CONFIG=$(merge_and_load "$E_HOME")

          echo "$E_CONFIG" | jq -e '.mcp_servers."user-server".url == "http://user-mcp"' > /dev/null \
            || fail "E: user MCP server not preserved"
          echo "$E_CONFIG" | jq -e '.mcp_servers."nix-server".command == "echo"' > /dev/null \
            || fail "E: Nix MCP server did not override same-name user server"
          echo "$E_CONFIG" | jq -e '.mcp_servers."nix-server".args == ["nix"]' > /dev/null \
            || fail "E: Nix MCP server args wrong"
          echo "PASS: Scenario E"

          # ═══════════════════════════════════════════════════════════════
          # Scenario F: Nested deep merge
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario F: Nested deep merge ==="
          F_HOME=$(mktemp -d)
          install -m 0644 ${fixtureF} "$F_HOME/config.yaml"
          F_CONFIG=$(merge_and_load "$F_HOME")

          echo "$F_CONFIG" | jq -e '.terminal.backend == "docker"' > /dev/null \
            || fail "F: Nix terminal.backend did not override"
          echo "$F_CONFIG" | jq -e '.terminal.timeout == 999' > /dev/null \
            || fail "F: Nix terminal.timeout did not override"
          echo "$F_CONFIG" | jq -e '.terminal.custom_key == "preserved"' > /dev/null \
            || fail "F: terminal.custom_key not preserved"
          echo "$F_CONFIG" | jq -e '.terminal.cwd == "/user/path"' > /dev/null \
            || fail "F: user terminal.cwd not preserved when Nix does not set it"
          echo "$F_CONFIG" | jq -e '.terminal.env_passthrough == ["USER_VAR"]' > /dev/null \
            || fail "F: user terminal.env_passthrough not preserved"
          echo "PASS: Scenario F"

          # ═══════════════════════════════════════════════════════════════
          # Scenario G: Idempotency — merging twice yields the same result
          # ═══════════════════════════════════════════════════════════════
          echo "=== Scenario G: Idempotency ==="
          G_HOME=$(mktemp -d)
          install -m 0644 ${fixtureD} "$G_HOME/config.yaml"
          ${configMergeScript} ${nixSettings} "$G_HOME/config.yaml"
          FIRST=$(cat "$G_HOME/config.yaml")
          ${configMergeScript} ${nixSettings} "$G_HOME/config.yaml"
          SECOND=$(cat "$G_HOME/config.yaml")

          if [ "$FIRST" != "$SECOND" ]; then
            fail "G: second merge produced different output"
            echo "--- first ---"
            echo "$FIRST"
            echo "--- second ---"
            echo "$SECOND"
          fi
          echo "PASS: Scenario G"

          # ═══════════════════════════════════════════════════════════════
          # Report
          # ═══════════════════════════════════════════════════════════════
          if [ -n "$ERRORS" ]; then
            echo ""
            echo "FAILURES:"
            echo -e "$ERRORS"
            exit 1
          fi

          echo ""
          echo "=== All 7 merge scenarios passed ==="
          mkdir -p $out
          echo "ok" > $out/result
        '';
      };
    };
}
