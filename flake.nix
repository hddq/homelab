{
  description = "Homelab Playground - Full Auto Setup";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        python3
        kubectl
        kubernetes-helm
        age
        sops
        argocd
        yamllint
        kubeconform
        trivy
        kubectx
        gitleaks
        pluto
        pre-commit
        shellcheck
        opentofu
        deploy-rs
        wireguard-tools
        qrencode
        statix
        deadnix
        alejandra
        ruff
        talosctl
        talhelper
        yq-go
        kyverno
      ];

      shellHook = ''
        echo "🚀 Loading Homelab environment..."

        if [ ! -d .venv ]; then
          echo "🐍 Creating new venv..."
          python3 -m venv .venv
        fi
        source .venv/bin/activate

        pip install -r ansible/requirements.txt --disable-pip-version-check

        SITE_PACKAGES=$(find .venv/lib -name "site-packages" -type d | head -n 1)
        export PYTHONPATH="$(pwd)/$SITE_PACKAGES:$PYTHONPATH"

        export ANSIBLE_COLLECTIONS_PATH="$(pwd)/.ansible/collections"
        export ANSIBLE_ROLES_PATH="$(pwd)/.ansible/roles"

        if [ -f ansible/requirements.yaml ]; then
           echo "📦 Checking Ansible collections..."
           ansible-galaxy install -r ansible/requirements.yaml
        fi

        pre-commit install

        echo "✅ Ready! Python: $(which python)"
      '';
    };
  };
}
