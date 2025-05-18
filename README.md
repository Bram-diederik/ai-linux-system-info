# ai-linux-system-info
Linux system info into the Home assistant AI

Get Loads of information from a Linux host and ask questions about it.

![Screenshot 0](/images/assistant0.jpg "Application Screenshot")![Screenshot1](/images/assistant1.jpg "Application Screenshot")

A script is run over ssh on the remote host. With a user with the systemd-journal rights. (will be added during setup)
advanced scanning like smartcrl are not included because that requires sudo and more automated config that might break.


# Install 

copy the /share/sys_info to /share/sys_info in the Home assistant envoirment. 
make sure the sh scripts are executable. `chmod +x *sh`

# Setup 

```
./deploy_sys_info.sh <server name> <user>@<server address>
```

The setup will generate a password less key. (limited to this script only on remote server) 
and uses this to setup the script (installed in ~./bin) 
and runs the internal setup. (battery check, and selecting services) 

# Home assistant integration

add or apply the following to the home assistant configuration.yaml file.
```
shell_command:
   system_info: /share/sys_info/get_sys_info.sh {{server}}
```

restart home assistant 
Then add the script in home assistant 

and make the script known to the AI. (i did not needed to edit the prompt)

# Note
I have a text and json output. json is better for a AI but when i finished the script. 
json did not work on all systems i deployed the script on. so i falled back to text.


This script is developed and created for HAOS. 
If you use a other variant then HAOS you're probabbly an idiot or an expert.
Meaning you can figure it out. or i can never help you.
You are on your own,
