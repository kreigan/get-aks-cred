# get-aks-cred

Allows you to quickly get credentials for your AKS clusters. Define TOML and run the
script. Will overwrite existing `~/.kube/config` but creates a backup first.

Multiple TOML files can be used to organize but they all should use one Azure account.
The script will also merge the user entries created by `kubelogin` for each managed
context into a single user entry in the kubeconfig.


## Requirements

- `az`, `kubectl`, `kubelogin`, `jq`, and Python 3.11 or newer (for the `tomllib`
module) are installed.
- You are logged in to the target tenant with `az login`, and your account has access
to the subscriptions listed in the cluster definitions.
- Clusters are described in TOML files under `~/.config/kube/` (or in the directory set
by `KUBE_DATA_DIR`).

## Installation and usage

1. Install the tools (I use `mise` to manage them):
   ```bash
   mise use -g azure azure-kubelogin kubectl jq python@3.12
   ```

2. Create the directory for cluster definitions:
   ```bash
   mkdir -p $HOME/.config/kube
   ```

3. Describe your clusters in a TOML file:
   ```bash
   cat <<EOF > $HOME/.config/kube/prod.toml
   [[kube.aks.clusters]]
   alias = "prod"
   subscription = "914d50d8-7ed6-4396-8ee1-fece25ad82ba"
   name = "my-prod-cluster"
   resource_group = "my-prod"
   namespace = "production"
   EOF
   ```

4. Set the browser used for Azure login (WSL):
   ```bash
   export BROWSER='/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
   ```
   To keep the variable between sessions, add this line to `~/.bashrc`.

5. Log in to the tenant (a browser window opens):
   ```bash
   az login --tenant mytenant.onmicrosoft.com
   ```

6. Download the script:
   ```bash
   wget https://github.com/kreigan/get-aks-cred/raw/refs/heads/main/getaks.sh -O ~/getaks.sh

8. Run the script:
   ```bash
   bash ~/getaks.sh
   ```

## Environment variables

- `AKS_TENANT` (optional): tenant domain or GUID. If set, the script checks that `az` is logged in to this tenant.
- `AKS_KUBE_CANON_USER` (optional): name of the shared user entry in kubeconfig. Defaults to `aks-user`.
- `KUBE_DATA_DIR` (optional): directory with TOML files. Defaults to `~/.config/kube`.
- `KUBE_LOG_FILE` (optional): path to an additional log file.
