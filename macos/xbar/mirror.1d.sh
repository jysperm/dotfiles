#!/usr/bin/env bash

# brew install fcanas/tap/mirror-displays
# (https://github.com/fcanas/mirror-displays)

export PATH=/usr/local/bin:$PATH

if [[ "$1" = "toggle" ]]; then
    mirror
fi

echo "Mirror: $(mirror -q)"
echo "---"
echo "Toggle | shell=${0} param1=toggle refresh=true"
