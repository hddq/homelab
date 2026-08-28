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
  };

  networking.firewall.allowedTCPPorts = [5353 9167];
  networking.firewall.allowedUDPPorts = [5353];
}
