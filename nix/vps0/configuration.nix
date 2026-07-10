{modulesPath, ...}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = ["xhci_pci" "usbhid" "virtio_pci" "virtio_blk"];

  networking.hostName = "vps0";
  networking.useDHCP = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [22];

  services.openssh = {
    enable = true;
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
    extraGroups = ["networkmanager" "wheel"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKFgv0ykKB0lLGjkh3fI8tUy+o8qtUcgjFPSN1AyncW hddq@main"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.settings.trusted-users = ["hddq"];

  system.stateVersion = "26.05";
}
