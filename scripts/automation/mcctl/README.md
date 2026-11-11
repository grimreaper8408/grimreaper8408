# mcctl - build with aid of lumo.proton.me AI

`mcctl` is a small Bash helper for starting, stopping, and monitoring multiple Minecraft servers that each run in their own `screen` session. Server names and directories are defined in a YAML config file, so you can add or change servers without editing the script.

## Features

- Start, stop, restart, and check the status of named Minecraft servers
- List all configured servers and whether each is running
- Attach to a server's `screen` console
- Graceful shutdown through `mc` (RCON) when available, with a fallback to quitting the session
- Server definitions kept in `/etc/minecraft/servers.yaml`, with input validation on every name and path

---

## Requirements

| Requirement | Notes |
|---|---|
| Linux with Bash | Requires Bash 4 or later, since the script uses associative arrays. |
| `screen` | Each server runs in its own detached session. |
| `yq` (mikefarah, v4) | Used to read the YAML config. The Python `yq` uses different syntax and will not work. |
| `keepalive.sh` | Launches and supervises each server. Expected at `/opt/minecraft/keepalive.sh`. This is not included in this repo. |
| `mc` (optional) | RCON helper for graceful stops. If it is not installed, `mcctl` quits the `screen` session instead. |

---

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/YOUR-USER/mcctl.git
   cd mcctl
   ```

2. Install the script:

   ```bash
   sudo install -m 755 -o root -g root mcctl /usr/local/bin/mcctl
   ```

3. Create the config directory and copy the example config:

   ```bash
   sudo mkdir -p /etc/minecraft
   sudo cp servers.yaml.example /etc/minecraft/servers.yaml
   sudo chown root:root /etc/minecraft /etc/minecraft/servers.yaml
   sudo chmod 755 /etc/minecraft
   sudo chmod 644 /etc/minecraft/servers.yaml
   ```

4. Edit the config to match your servers (see [Configuration](#configuration)).

5. Confirm that `keepalive.sh` is owned by root and is not writable by other users:

   ```bash
   ls -l /opt/minecraft/keepalive.sh
   # Expected: -rwxr-xr-x 1 root root ...
   ```

---

## Configuration

Servers are defined in `/etc/minecraft/servers.yaml`:

```yaml
servers:
  survival:
    dir: /home/minecraft/survival
  creative:
    dir: /home/minecraft/creative
  modpack:
    dir: /home/minecraft/modpack
```

Each entry has the following rules:

- **Name** (the key): 1 to 32 characters, using only lowercase letters, digits, `-`, and `_`.
- **`dir`**: an absolute path to an existing directory. Entries that fail validation cause the script to exit with an error that names the bad entry.

Multiple servers can share a directory if needed, for example two worlds run from the same server folder.

---

## Usage

```bash
mcctl <command> [name]
```

| Command | Description |
|---|---|
| `list` | Show every configured server and whether it is running. This is the default when no command is given. |
| `start <name>` | Start the server in a detached `screen` session. |
| `stop <name>` | Stop the server gracefully if `mc` is available, then end the `screen` session. |
| `restart <name>` | Run `stop`, wait two seconds, then run `start`. |
| `status <name>` | Show the `screen` session ID and matching `keepalive.sh` processes. |
| `attach <name>` | Attach to the server's `screen` console. Detach with `Ctrl-a d`. |

### Examples

```bash
mcctl list
mcctl start survival
mcctl status creative
mcctl restart modpack
mcctl attach survival
```

---

## Permissions and Access Control

`mcctl` does not handle authentication itself. Access is controlled by the system:

- Anyone who can run `mcctl attach` gets the server console with full operator rights. Limit who can run it.
- If you grant sudo access to `mcctl`, add a narrow rule in `/etc/sudoers.d/` rather than allowing it broadly.
- `/etc/minecraft/servers.yaml` should be owned by root and not writable by regular users, because it determines which directories are trusted.
- Keep `keepalive.sh` root-owned and not writable by the server user, since it may run with elevated privileges.

The script sets a fixed `PATH` so that it does not run binaries from user-writable directories.

---

## Troubleshooting

**`yq is required`**
Install the mikefarah v4 build of `yq`. Check which version you have with `yq --version`. The output should mention `mikefarah`.

**`Cannot read /etc/minecraft/servers.yaml`**
The file is missing or not readable by the user running `mcctl`. Check the path and permissions.

**`Invalid server name` or `Bad or missing dir`**
Check the entry named in the error. Names must match the allowed character set, and `dir` must be an absolute path to an existing directory.

**`X not running.` when you expect it to be running**
Run `screen -ls` to see the actual session names. `mcctl` matches the session name exactly, so a session with a different name will not be detected.

**Server does not stop cleanly**
If `mc` is not set up for RCON, `mcctl` quits the `screen` session without a graceful save. Install and configure `mc` for a clean shutdown.

---

## Project Layout

```
mcctl/
├── mcctl                 # The control script
├── servers.yaml.example  # Example config to copy to /etc/minecraft/
└── README.md
```

---

## License

MIT.
