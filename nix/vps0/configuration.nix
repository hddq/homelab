{config, modulesPath, ...}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    initrd.availableKernelModules = ["xhci_pci" "usbhid" "virtio_pci" "virtio_blk"];
    kernel.sysctl."net.ipv4.ip_forward" = 1;
  };

  networking = {
    hostName = "vps0";
    useDHCP = true;
    firewall.enable = true;
    firewall.allowedTCPPorts = [2222];
    firewall.allowedUDPPorts = [51820];
    wireguard.interfaces = {
      wg0 = {
        ips = [ "192.168.70.2/24" ];
        listenPort = 51820;
        privateKeyFile = config.sops.secrets.wireguard_private_key.path;

        peers = [
          {
            # tundra
            publicKey = "Ew6QN2qyHDu7JYFFz7Y+o+kfMVSFFthk+DS16xo7D1g=";
            allowedIPs = [ "192.168.70.15/32" ];
          }
        ];
      };
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
    extraGroups = ["wheel"];
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
    secrets.example = {};
    secrets.wireguard_private_key = {};
  };

  system.stateVersion = "26.05";
}
