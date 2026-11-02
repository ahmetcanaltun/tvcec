#!/bin/zsh
# Usage: ./install.sh     (asks for the sudo password)
set -eu
cd "${0:A:h}"
LABEL=com.ahmetaltun.tvcec
BIN=/usr/local/bin/tvcec
SUDOERS=/etc/sudoers.d/tvcec
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh
build/tvcec selftest >/dev/null || { print -u2 "selftest failed"; exit 1; }

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
sudo mkdir -p "${BIN:h}"
sudo install -o root -g wheel -m 755 build/tvcec "$BIN"

RULE=$(mktemp)
print "$USER ALL=(root) NOPASSWD: $BIN wake, $BIN standby" > "$RULE"
sudo visudo -cf "$RULE" >/dev/null
sudo install -o root -g wheel -m 440 "$RULE" "$SUDOERS"
rm -f "$RULE"

sudo "$BIN" status || { print -u2 "\ntvcec could not reach the TV over CEC, so the agent was not started. Run ./uninstall.sh to remove it."; exit 2; }

mkdir -p "${PLIST:h}" "$HOME/Library/Logs/tvcec"
sed "s|__HOME__|$HOME|g" "$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
print "installed. log: $HOME/Library/Logs/tvcec/tvcec.log"
