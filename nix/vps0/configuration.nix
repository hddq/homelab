{modulesPath, ...}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./wireguard.nix
    ./unbound.nix
    ./blocky.nix
    ./qnetd.nix
  ];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    initrd.availableKernelModules = ["xhci_pci" "usbhid" "virtio_pci" "virtio_blk"];
  };

  networking = {
    hostName = "vps0";
    useDHCP = true;
    nameservers = ["192.168.40.11" "192.168.40.12"];
    firewall = {
      enable = true;
      allowedTCPPorts = [2222];
    };
  };

  services.openssh = {
    enable = true;
    ports = [2222];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  programs.ssh.startAgent = true;
  users.users.hddq = {
    isNormalUser = true;
    description = "hddq";
    extraGroups = ["wheel" "coroqnetd"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKFgv0ykKB0lLGjkh3fI8tUy+o8qtUcgjFPSN1AyncW hddq@main"
    ];
  };
  security.sudo.wheelNeedsPassword = false;
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
    settings.trusted-users = ["hddq"];
  };

  sops = {
    defaultSopsFile = ./secret.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets = {
      example = {};
    };
  };

  system.stateVersion = "26.05";
}
