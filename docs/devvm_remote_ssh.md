# Connecting to the Dev VM via VS Code Remote-SSH

## 0. Generate an SSH Key Pair (if you don't have one)

Open a terminal and run:

```powershell
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
```

Accept the default location (`~/.ssh/id_rsa`) and optionally set a passphrase.

This creates two files:

- `~/.ssh/id_rsa` — **private key** (never share this)
- `~/.ssh/id_rsa.pub` — **public key** (added to the VM)

### Add your public key to the dev VM

```powershell
# Replace with your actual public key content
$pubKey = Get-Content ~/.ssh/id_rsa.pub
ssh devadmin@20.80.99.213 "mkdir -p ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Or if your key was already configured when the VM was provisioned (via `scripts/provision-dev.ps1`), you can skip this step.

---

In VS Code, install **Remote - SSH** (Microsoft) from the Extensions marketplace.

---

## 2. Add the Host to SSH Config

Open the Command Palette (`Ctrl+Shift+P`) → **Remote-SSH: Open SSH Configuration File** → select `C:\Users\<you>\.ssh\config`

Add:

```
Host eq-tech-devbox
    HostName 20.80.99.213
    User devadmin
    IdentityFile ~/.ssh/id_rsa
```

> Replace `~/.ssh/id_rsa` with the path to the private key that matches the public key on the VM. If you have been SSHing in from the terminal it is the same key.

---

## 3. Connect

`Ctrl+Shift+P` → **Remote-SSH: Connect to Host** → select **eq-tech-devbox**

VS Code opens a new window connected to the VM. Open the folder `/home/devadmin/eq_tech` or `/opt/eq-tech`.

---

## 4. Open the Repo Folder

Once connected, **File → Open Folder** → `/home/devadmin/eq_tech` (or wherever the repo is cloned on the VM).

---

## Notes

- The VM IP (`20.80.99.213`) changes each time it is deallocated and restarted — update the `HostName` in the SSH config accordingly, or run `scripts\resume-devvm.ps1` to see the current IP.
- To get the current IP dynamically without editing the config:
  ```powershell
  ssh devadmin@$(az vm show -g eq-tech-rg -n eq-tech-devbox --show-details --query publicIps -o tsv)
  ```
- To start the VM before connecting:
  ```powershell
  .\scripts\resume-devvm.ps1
  ```
