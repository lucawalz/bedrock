let
  nodes = {
    control-plane-1 = {
      role = "server";
      address = "10.20.0.10";
      mac = "98:fa:9b:a0:67:b7";
      tailscale = {
        address = "100.105.211.67";
        magicDnsName = "control-plane-1.tail26ab10.ts.net";
      };
    };
    worker-1 = {
      role = "agent";
      address = "10.20.0.11";
      mac = "98:fa:9b:a0:63:24";
    };
    worker-2 = {
      role = "agent";
      address = "10.20.0.12";
      mac = "98:fa:9b:34:bc:10";
    };
  };
  namesWithRole = role: builtins.filter (name: nodes.${name}.role == role) (builtins.attrNames nodes);
  knownRoles = [
    "server"
    "agent"
  ];
  badRole = builtins.filter (name: !builtins.elem nodes.${name}.role knownRoles) (
    builtins.attrNames nodes
  );
  bootstrapControlPlane = "control-plane-1";
  controlPlanes = namesWithRole "server";
in
assert
  badRole == [ ]
  || throw "inventory: node '${builtins.head badRole}' has an unknown role '${
    nodes.${builtins.head badRole}.role
  }'";
assert
  builtins.elem bootstrapControlPlane controlPlanes
  || throw "inventory: bootstrapControlPlane '${bootstrapControlPlane}' is not a member of controlPlanes";
{
  subnet = "10.20.0.0/24";
  gateway = "10.20.0.1";
  serviceVip = "10.20.0.50";
  dhcpPool = "10.20.0.100 - 10.20.0.200";
  inherit
    bootstrapControlPlane
    controlPlanes
    nodes
    ;
}
