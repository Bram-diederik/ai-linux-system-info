#!/bin/sh
exec /usr/bin/ssh -o StrictHostKeyChecking=accept-new -i /share/sys_info/key "$@"
