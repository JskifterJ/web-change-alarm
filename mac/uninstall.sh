#!/bin/bash
# Removes the launchd agent installed by mac/install.sh.
#   bash mac/uninstall.sh                     (default label)
#   bash mac/uninstall.sh com.example.other   (if you installed with --label)
LABEL="${1:-com.webchangealarm.watch}"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Removed '$LABEL'."
