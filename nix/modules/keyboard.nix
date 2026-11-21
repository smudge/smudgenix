{ pkgs, lib, ... }:

lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  # A faster key repeat (GNOME's defaults are 500ms / 30ms).
  dconf.settings."org/gnome/desktop/peripherals/keyboard" =
    lib.mapAttrs (_: v: lib.mkDefault (lib.hm.gvariant.mkUint32 v)) {
      delay = 200;
      repeat-interval = 25;
    };
}
