{pkgs, ...}: {
  environment.systemPackages = [pkgs.corosync-qdevice pkgs.nssTools];

  users.groups.coroqnetd = {};
  users.users.coroqnetd = {
    isSystemUser = true;
    group = "coroqnetd";
    home = "/etc/corosync/qnetd";
  };

  systemd.tmpfiles.rules = [
    "d /etc/corosync 0755 root root -"
    "d /etc/corosync/qnetd 0770 coroqnetd coroqnetd -"
  ];

  systemd.services.corosync-qnetd = {
    description = "Corosync Qdevice Network Daemon";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.nssTools pkgs.corosync-qdevice];
    serviceConfig = {
      RuntimeDirectory = "corosync-qnetd";
      ExecStartPre = [
        "+${pkgs.bash}/bin/bash -c 'if [ ! -f /etc/corosync/qnetd/nssdb/cert9.db ]; then ${pkgs.corosync-qdevice}/bin/corosync-qnetd-certutil -i; fi'"
        "+${pkgs.bash}/bin/bash -c 'chown -R coroqnetd:coroqnetd /etc/corosync/qnetd'"
      ];
      ExecStart = "${pkgs.corosync-qdevice}/bin/corosync-qnetd -f";
      User = "coroqnetd";
      Group = "coroqnetd";
      Restart = "on-failure";
    };
  };

  networking.firewall.allowedTCPPorts = [5403];
}
