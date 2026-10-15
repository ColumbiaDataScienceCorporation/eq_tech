# Connecting to the Dev VM via VS Code Remote-SSH

## 1. Install the Extension

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
