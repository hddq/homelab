{
  inputs,
  pkgs,
  modulesPath,
  ...
}: let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
    overlays = [inputs.t3code-nix.overlays.default];
  };
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-cleanup.nix
  ];

  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };
    initrd.availableKernelModules = ["xhci_pci" "usbhid" "virtio_pci" "virtio_scsi" "virtio_blk"];
  };

  networking = {
    hostName = "forge";
    useDHCP = false;
    useNetworkd = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [22 3773];
    };
  };

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "en*";
      address = ["192.168.20.18/24"];
      gateway = ["192.168.20.1"];
      dns = ["192.168.41.13" "192.168.70.2"];
      linkConfig.RequiredForOnline = "routable";
    };
  };

  services = {
    qemuGuest.enable = true;

    openssh = {
      enable = true;
      ports = [22];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    journald.extraConfig = ''
      SystemMaxUse=200M
      MaxRetentionSec=7day
    '';
  };

  programs = {
    fish.enable = true;
    ssh.startAgent = true;
    nix-ld.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      settings.whitelist.prefix = ["/home/hddq/.t3" "/home/hddq"];
      direnvrcExtra = ''
        direnv_layout_dir() {
          if [ -f "$PWD/flake.nix" ]; then
            local hash dir
            hash=$(sha256sum "$PWD/flake.nix" "$PWD/flake.lock" 2>/dev/null | cut -d' ' -f1 | sha256sum | cut -d' ' -f1)
            dir="$HOME/.cache/direnv-layouts/$hash"
            if [ -d "$dir" ]; then
              touch -c "$dir" "$dir"/flake-profile*.rc 2>/dev/null || true
            fi
            echo "$dir"
          else
            echo "$PWD/.direnv"
          fi
        }
      '';
    };
  };

  users.users.hddq = {
    isNormalUser = true;
    description = "hddq";
    extraGroups = ["wheel"];
    linger = true;
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKFgv0ykKB0lLGjkh3fI8tUy+o8qtUcgjFPSN1AyncW hddq@main"
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {inherit pkgs-unstable;};
    users.hddq = {
      home = {
        stateVersion = "26.05";

        file = {
          ".config/direnv/agent-env.sh".text = ''
            unset BASH_ENV ENV

            if [ -z "''${IN_NIX_SHELL:-}" ] && [ -z "''${DIRENV_DIR:-}" ]; then
              export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/hddq/bin:$PATH"
              if command -v direnv >/dev/null 2>&1; then
                eval "$(flock -w 120 /tmp/direnv-agent.lock direnv export bash 2>/dev/null)"
              fi
              unset BASH_ENV ENV
            fi
          '';

          # Caches restoid's bundled librestic/librclone per submodule commit (hardlinked
          # across worktrees). Machine-local on purpose: F-Droid builds never see it.
          ".gradle/init.d/native-lib-cache.gradle".source = ./native-lib-cache.init.gradle;
        };

        packages = [
          pkgs-unstable.kiro-cli
        ];
      };

      systemd.user.services.t3code.Service.Environment = [
        "SHELL=/run/current-system/sw/bin/bash"
        "DIRENV_CONFIG=/etc/direnv"
        "BASH_ENV=%h/.config/direnv/agent-env.sh"
        "T3CODE_NO_AGENT_SCOPES=1"
      ];

      programs = {
        gh = {
          enable = true;
          gitCredentialHelper.enable = true;
        };

        git = {
          enable = true;
          settings.user = {
            name = "hddq";
            email = "git@hddq.org";
          };
          # Written by forge-disk-cleanup once the local submodule mirrors exist;
          # git ignores a missing include file.
          includes = [{path = "/home/hddq/.config/git/forge-mirrors.inc";}];
        };

        t3code = {
          enable = true;
          package = pkgs-unstable.t3code;
          server = {
            enable = true;
            extraArgs = [
              "--host"
              "0.0.0.0"
              "--port"
              "3773"
            ];
          };
        };
      };
    };
  };

  security.sudo.wheelNeedsPassword = false;

  systemd.coredump.settings.Coredump = {
    MaxUse = "100M";
    KeepFree = "2G";
  };

  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["hddq"];
      auto-optimise-store = true;
      min-free = 5 * 1024 * 1024 * 1024;
      max-free = 12 * 1024 * 1024 * 1024;
    };
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 3d";
    };
    optimise.automatic = true;
  };

  system.stateVersion = "26.05";
}
