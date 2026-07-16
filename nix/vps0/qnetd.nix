{...}: {
  imports = [
    ./corosync-qnetd.nix
  ];

  services.corosync-qnetd.enable = true;
  services.corosync-qnetd.openFirewall = true;
}
