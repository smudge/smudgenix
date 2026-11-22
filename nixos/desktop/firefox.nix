# Firefox, when it's the browser: quiet defaults and smudgenix's layout, as
# system-wide policies (in /etc/firefox, so any Firefox reads them). Each
# setting is only a default, which Firefox's own settings can change.
#
# Its colors follow Noctalia's, via the Pywalfox extension: Noctalia renders
# a Pywal colors file from its palette, and serves it to the extension as its
# native host (installing ~/.mozilla/native-messaging-hosts/pywalfox.json).
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) apps desktop;
  isFirefox = lib.hasPrefix "firefox" (lib.getName apps.browser);

  # Pywalfox's dark theme uses colors 0 (background), 10 & 13 (accents) and
  # 15 (text), and derives its lighter backgrounds from color 0.
  colorsTemplate = pkgs.writeText "pywal-colors.json" (
    let c = name: "{{ colors.${name}.default.hex }}"; in builtins.toJSON {
      wallpaper = "{{ image }}";
      special = { background = c "surface"; foreground = c "on_surface"; cursor = c "primary"; };
      colors = lib.listToAttrs (lib.imap0 (i: name: lib.nameValuePair "color${toString i}" (c name)) [
        "surface" "error" "tertiary" "primary" "secondary" "tertiary" "secondary" "on_surface_variant"
        "surface_container_high" "error" "primary" "tertiary" "secondary" "tertiary" "on_surface_variant" "on_surface"
      ]);
    }
  );

  pref = value: { Value = value; Status = "default"; };
in
lib.mkIf (desktop.niri.enable && isFirefox) {
  environment.etc."firefox/policies/policies.json".source =
    (pkgs.formats.json { }).generate "firefox-policies.json" {
      policies = {
        # Quiet: no telemetry, studies, sponsored content or nags.
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        DisablePocket = true;
        DontCheckDefaultBrowser = true;
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        UserMessaging = {
          ExtensionRecommendations = false;
          FeatureRecommendations = false;
          MoreFromMozilla = false;
          SkipOnboarding = true;
          UrlbarInterventions = false;
          WhatsNew = false;
          Locked = false;
        };
        FirefoxHome = {
          SponsoredTopSites = false;
          SponsoredStories = false;
          SponsoredPocket = false;
          Stories = false;
          Pocket = false;
          Locked = false;
        };
        FirefoxSuggest = {
          SponsoredSuggestions = false;
          ImproveSuggest = false;
          Locked = false;
        };

        ExtensionSettings."pywalfox@frewacom.org" = {
          installation_mode = "normal_installed";
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi";
        };

        Preferences = lib.mapAttrs (_: pref) {
          # Layout: tabs down the side, no bookmarks bar, and pick up where
          # you left off.
          "sidebar.revamp" = true;
          "sidebar.verticalTabs" = true;
          "browser.toolbars.bookmarks.visibility" = "never";
          "browser.startup.page" = 3;
          # Quiet: no trending searches in the address bar.
          "browser.urlbar.suggest.trending" = false;
        };
      };
    };

  smudgenix.desktop.noctalia.settings.theme.templates.user.firefox = lib.mapAttrs (_: lib.mkDefault) {
    input_path = "${colorsTemplate}";
    output_path = "$XDG_CACHE_HOME/wal/colors.json";
    post_action = "firefox-theme";
  };
}
