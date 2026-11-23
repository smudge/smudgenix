# opencode, wrapped to use the OS's `opencode` user service, if any (see
# ./opencode.sh). Shared by the OS and homes, so either one on PATH behaves the
# same.
pkgs:

let
  inherit (pkgs) opencode;
in
(pkgs.writeShellApplication {
  name = "opencode";
  text = ''
    opencode=${pkgs.lib.getExe opencode}
  '' + builtins.readFile ./opencode.sh;
}).overrideAttrs (old: {
  passthru = (old.passthru or { }) // { unwrapped = opencode; };
  meta = (old.meta or { }) // { inherit (opencode.meta) description; mainProgram = "opencode"; };
})
