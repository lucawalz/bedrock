{
  secretsDir ? ../../secrets,
  ...
}:
{
  imports = [ ./estate.nix ];

  age.secrets.k3s-token = {
    file = "${secretsDir}/k3s-token.age";
    mode = "0400";
    owner = "root";
    group = "root";
  };

  environment.etc."k3s/flannel-net-conf.json".text =
    ''{"Network":"10.42.0.0/16","Backend":{"Type":"vxlan","MTU":1280}}'';

  services.k3s.extraFlags = [
    "--flannel-conf=/etc/k3s/flannel-net-conf.json"
  ];
}
