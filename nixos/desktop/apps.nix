# The default desktop apps (`smudgenix.apps.*`): installed, opened by their
# keybinds, and set as the default for their file types. Terminal apps (like
# yazi) open in the terminal, via xdg-terminal-exec.
{ config, lib, pkgs, ... }:

let
  cfg = config.smudgenix.apps;

  # Each app's desktop entry, e.g. "firefox.desktop". (Checked at build time.)
  desktopEntry = pkg: cfg.desktopEntries.${lib.getName pkg} or "${lib.getName pkg}.desktop";

  defaultsFor = pkg: types: lib.genAttrs types (_: lib.mkDefault (desktopEntry pkg));

  checkEntries = pkgs.runCommand "smudgenix-app-desktop-entries" { } (lib.concatMapStrings (pkg: ''
    if [ ! -e ${pkg}/share/applications/${desktopEntry pkg} ]; then
      echo "smudgenix: ${lib.getName pkg} has no ${desktopEntry pkg}; set smudgenix.apps.desktopEntries.${lib.getName pkg} to one of:" >&2
      ls ${pkg}/share/applications >&2 || true
      exit 1
    fi
  '') (lib.unique (builtins.attrValues apps)) + "touch $out");

  apps = { inherit (cfg) browser terminal fileManager imageViewer pdfViewer; };
in
{
  options.smudgenix.apps = {
    browser = lib.mkPackageOption pkgs "firefox" { };
    terminal = lib.mkPackageOption pkgs "alacritty" { };
    fileManager = lib.mkPackageOption pkgs "yazi" { };
    imageViewer = lib.mkPackageOption pkgs "imv" { };
    pdfViewer = lib.mkOption {
      type = lib.types.package;
      default = cfg.browser;
      defaultText = lib.literalExpression "config.smudgenix.apps.browser";
      description = "The PDF viewer (by default, the browser).";
    };

    filePicker = lib.mkOption {
      type = lib.types.enum [ "yazi" "gtk" ];
      default = "yazi";
      description = ''
        The file chooser apps use in tiling sessions (via the desktop portal):
        yazi in a terminal, or GTK's dialog.
      '';
    };

    desktopEntries = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { kitty = "kitty.desktop"; };
      description = ''
        Desktop entries of apps (by package name) whose entry isn't
        `<name>.desktop`, for any app smudgenix doesn't already know.
      '';
    };

    entries = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      description = "Each app's desktop entry file (e.g. for `gio launch`).";
    };
  };

  config = lib.mkIf config.smudgenix.desktop.niri.enable {
    smudgenix.apps.entries = lib.mapAttrs (_: pkg: "${pkg}/share/applications/${desktopEntry pkg}") apps;

    smudgenix.apps.desktopEntries = lib.mapAttrs (_: lib.mkDefault) {
      alacritty = "Alacritty.desktop";
      eog = "org.gnome.eog.desktop";
      ghostty = "com.mitchellh.ghostty.desktop";
      loupe = "org.gnome.Loupe.desktop";
      nautilus = "org.gnome.Nautilus.desktop";
      papers = "org.gnome.Papers.desktop";
    };

    environment.systemPackages = lib.unique (builtins.attrValues apps);
    system.checks = [ checkEntries ];

    # Default apps by file type. (Hosts can override any one of them.)
    xdg.mime.defaultApplications =
      defaultsFor cfg.browser [
        "text/html"
        "application/xhtml+xml"
        "x-scheme-handler/http"
        "x-scheme-handler/https"
      ]
      // defaultsFor cfg.pdfViewer [ "application/pdf" ]
      // defaultsFor cfg.fileManager [ "inode/directory" ]
      // defaultsFor cfg.imageViewer [
        "image/png"
        "image/jpeg"
        "image/gif"
        "image/webp"
        "image/avif"
        "image/heif"
        "image/jxl"
        "image/bmp"
        "image/tiff"
        "image/svg+xml"
      ];

    # Open terminal apps (e.g. from file managers, or the launcher) in the
    # chosen terminal.
    xdg.terminal-exec = {
      enable = true;
      settings.default = [ (desktopEntry cfg.terminal) ];
    };
    environment.sessionVariables.TERMINAL = lib.getExe cfg.terminal;
  };
}
