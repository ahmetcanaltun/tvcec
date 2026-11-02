#!/bin/zsh
# Usage: ./uninstall.sh [--purge-logs]     (asks for the sudo password)
set -eu
LABEL=com.ahmetaltun.tvcec
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
sudo rm -f /etc/sudoers.d/tvcec /usr/local/bin/tvcec /var/run/tvcec.lock
if [[ "${1:-}" == "--purge-logs" ]]; then
    rm -rf "$HOME/Library/Logs/tvcec"
fi
print "uninstalled"
