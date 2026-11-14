{
  pkgs,
  modulesPath,
  ...
}: {
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
      allowedTCPPorts = [22];
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
  };

  users.users.hddq = {
    isNormalUser = true;
    description = "hddq";
    extraGroups = ["wheel"];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKFgv0ykKB0lLGjkh3fI8tUy+o8qtUcgjFPSN1AyncW hddq@main"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
    settings.trusted-users = ["hddq"];
  };

  system.stateVersion = "26.05";
}
