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
