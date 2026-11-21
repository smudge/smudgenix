{ config, lib, ... }:

let
  cfg = config.smudgenix;
in
{
  options.smudgenix.windowsCompat = lib.mkEnableOption
    "dual-booting with Windows (os-prober, NTFS, local-time hardware clock)";

  config = {
    # Prefer GRUB:
    boot.loader = {
      systemd-boot.enable = false;
      efi.canTouchEfiVariables = true;
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
        useOSProber = cfg.windowsCompat;
        extraEntries = ''
          menuentry "Reboot" {
            reboot
          }
          menuentry "Poweroff" {
            halt
          }
        '';
      };
    };

    # Show boot spinner:
    boot.kernelParams = [ "quiet" ];
    boot.plymouth.enable = true;

    boot.supportedFilesystems = lib.mkIf cfg.windowsCompat [ "ntfs" ];
    time.hardwareClockInLocalTime = cfg.windowsCompat;
  };
}
