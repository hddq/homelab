{
  inputs,
  pkgs,
  modulesPath,
  ...
}: let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
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

  services.openssh = {
    enable = true;
    ports = [22];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  programs = {
    fish.enable = true;
    ssh.startAgent = true;
    nix-ld.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
      settings.whitelist.prefix = ["/home/hddq/.t3"];
    };
  };

  environment.systemPackages = with pkgs; [
    git
    gh
  ];

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
      home.stateVersion = "26.05";

      programs.git = {
        enable = true;
        settings.user = {
          name = "hddq";
          email = "git@hddq.org";
        };
      };

      home.file.".config/direnv/agent-env.sh".text = ''
        unset BASH_ENV ENV

        if [ -z "''${IN_NIX_SHELL:-}" ] && [ -z "''${DIRENV_DIR:-}" ]; then
          export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/hddq/bin:$PATH"
          if command -v direnv >/dev/null 2>&1; then
            eval "$(direnv export bash 2>/dev/null)"
          fi
          unset BASH_ENV ENV
        fi
      '';

      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
        config.whitelist.prefix = ["/home/hddq/.t3"];
      };

      systemd.user.services.t3code.Service.Environment = [
        "SHELL=/run/current-system/sw/bin/bash"
        "DIRENV_CONFIG=/etc/direnv"
        "BASH_ENV=%h/.config/direnv/agent-env.sh"
      ];

      programs.t3code = {
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

  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
    settings.trusted-users = ["hddq"];
  };

  system.stateVersion = "26.05";
}
