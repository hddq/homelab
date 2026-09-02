_: {
  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      server = {
        include = ["${../../shared/dns/unbound.conf}"];
      };
      remote-control = {
        control-enable = true;
        control-use-cert = false;
      };
    };
  };

  services.prometheus.exporters.unbound = {
    enable = true;
    openFirewall = true;
    unbound = {
      ca = null;
      certificate = null;
      key = null;
    };
    extraFlags = [
      "-unbound.ca="
      "-unbound.cert="
      "-unbound.key="
    ];
  };

  networking.firewall.allowedTCPPorts = [5353 9167];
  networking.firewall.allowedUDPPorts = [5353];
}
