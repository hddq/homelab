{
  description = "NixOS configuration for forge";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    deploy-rs,
    home-manager,
    ...
  } @ inputs: {
    nixosConfigurations."forge" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {inherit inputs;};
      modules = [
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
        ./disk-config.nix
        ./configuration.nix
      ];
    };

    deploy.nodes.forge = {
      hostname = "192.168.20.18";
      remoteBuild = false;
      profiles.system = {
        user = "root";
        sshUser = "hddq";
        path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations."forge";
      };
    };
  };
}
