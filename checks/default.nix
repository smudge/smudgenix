# Builds an example host and home from the templates' shape, so a broken push
# fails `nix flake check` instead of a machine's next daily update. And tests
# smx ai's normalizer.
{ self, nixpkgs }:

let
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};

  host = self.lib.mkSystem {
    settings = ./smudgenix.toml;
    modules = [
      ({ ... }: {
        nixpkgs.hostPlatform = system;
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        networking.hostName = "example";
        system.stateVersion = "26.11";
        smudgenix.desktop.niri.enable = true;
        smudgenix.user = {
          name = "example";
          git = { name = "Example"; email = "example@example.com"; };
        };
      })
    ];
  };

  home = self.lib.mkHome {
    username = "example";
    inherit system;
    stateVersion = "26.11";
    modules = [{
      smudgenix.git = { name = "Example"; email = "example@example.com"; };
    }];
  };
  # smx ai's normalizer, on recorded (and made-up) server events, its
  # layers' hotspots, on made-up changes, its history, on made-up sessions,
  # and its decision log's fold, on a made-up log.
  ai = pkgs.runCommand "smx-ai-tests" { nativeBuildInputs = [ pkgs.jq pkgs.diffutils ]; } ''
    for events in ${../ai/tests}/*.events.jsonl; do
      expected=''${events%.events.jsonl}.expected.jsonl
      echo "$(basename "$events")"
      jq -cn -f ${../ai/normalize.jq} < "$events" | diff -u "$expected" -
    done
    for change in ${../ai/tests}/*.hotspots.json; do
      echo "$(basename "$change")"
      jq -c -f ${../ai/hotspots.jq} "$change" | diff -u "''${change%.json}.expected.json" -
    done
    for sessions in ${../ai/tests}/*.history.json; do
      echo "$(basename "$sessions")"
      jq -c -f ${../ai/history.jq} "$sessions" | diff -u "''${sessions%.json}.expected.json" -
    done
    for log in ${../ai/tests}/*.fold.json; do
      echo "$(basename "$log")"
      jq -c -f ${../ai/decisions.jq} "$log" | diff -u "''${log%.json}.expected.json" -
    done
    touch $out
  '';
in
{
  ${system} = {
    host = host.config.system.build.toplevel;
    home = home.activationPackage;
    inherit ai;
  };
}
