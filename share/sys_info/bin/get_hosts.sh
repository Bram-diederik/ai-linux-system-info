#!/bin/bash
HOSTS=$(cut -d ' ' -f1 /share/sys_info/etc/hosts | jq -R . | jq -s .)
echo "{\"hosts\": $HOSTS}"
