# The smudge wallpaper: a soft graphite swipe with an ember edge. Drawn small
# and upscaled (it's all blur anyway), then grain is added at full size.
{ runCommand, imagemagick, colors }:

runCommand "smudge-wallpaper.png" { nativeBuildInputs = [ imagemagick ]; } ''
  W=960; H=600
  magick -size ''${W}x''${H} xc:"${colors.base00}" \
    \( -size ''${W}x''${H} xc:none -fill none \
       -stroke "${colors.base02}" -strokewidth 170 \
       -draw "path 'M -80,420 C 180,330 420,360 640,230 S 880,90 1040,40'" \
       -blur 0x34 \) -compose screen -composite \
    \( -size ''${W}x''${H} xc:none -fill none \
       -stroke "#3e4046" -strokewidth 46 \
       -draw "path 'M 60,500 C 280,360 480,400 650,270 S 840,150 930,95'" \
       -blur 0x9 -motion-blur 0x34+35 \) -compose screen -composite \
    \( -size ''${W}x''${H} xc:none -fill none \
       -stroke "${colors.base09}" -strokewidth 8 \
       -draw "path 'M 300,400 C 480,360 560,330 650,270 S 840,150 905,105'" \
       \( -size ''${W}x''${H} xc:none -channel RGBA \
          -sparse-color barycentric "420,0 #ffffff00 820,0 #ffffffff" \) \
       -compose DstIn -composite \
       -blur 0x4 -motion-blur 0x22+35 \) -compose screen -composite \
    \( -size ''${W}x''${H} radial-gradient:"#00000000-#00000070" \) -compose over -composite \
    -filter Lanczos -resize 2560x1600 \
    -seed 7 -attenuate 0.2 +noise Gaussian \
    -colorspace sRGB -depth 8 -strip -define png:exclude-chunks=date,time \
    png:$out
''
