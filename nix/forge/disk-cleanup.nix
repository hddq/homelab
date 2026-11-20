{
  pkgs,
  lib,
  ...
}: let
  cleanupApp = pkgs.writeShellScriptBin "forge-disk-cleanup" ''
    export PATH="${lib.makeBinPath [pkgs.python3 pkgs.git pkgs.nix pkgs.coreutils]}:$PATH"
    exec python3 ${./disk-cleanup.py} "$@"
  '';
in {
  environment.systemPackages = [cleanupApp];

  systemd = {
    services = {
      forge-disk-cleanup = {
        description = "Clean up stale T3 worktrees, direnv layouts, and build caches";
        serviceConfig = {
          Type = "oneshot";
          User = "hddq";
          Group = "users";
          Nice = 19;
          IOSchedulingClass = "idle";
          ExecStart = "${cleanupApp}/bin/forge-disk-cleanup";
        };
      };

      # Keeps bare mirrors of submodule upstreams (rclone, restic, ...) fresh so new
      # worktrees clone submodules locally instead of from GitHub every time.
      forge-git-mirrors = {
        description = "Refresh local git mirrors of submodule upstreams";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          User = "hddq";
          Group = "users";
          Nice = 19;
          IOSchedulingClass = "idle";
          ExecStart = "${cleanupApp}/bin/forge-disk-cleanup --refresh-mirrors";
        };
      };

      nix-gc = {
        wants = ["forge-disk-cleanup.service"];
        after = ["forge-disk-cleanup.service"];
      };
    };

    timers = {
      forge-disk-cleanup = {
        description = "Periodic disk space cleanup on forge";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "0/6:00:00";
          Persistent = true;
          RandomizedDelaySec = "10m";
        };
      };

      forge-git-mirrors = {
        description = "Periodic refresh of local submodule mirrors on forge";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "15m";
        };
      };
    };
  };
}
