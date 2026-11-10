#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${KUBE_DATA_DIR:-$HOME/.config/kube}"
KUBE_DIR="$HOME/.kube"
CONFIG="$KUBE_DIR/config"
LOG_FILE="${KUBE_LOG_FILE:-}"   # optional: also write logs to this file

TENANT="${AKS_TENANT:-}"                       # optional
CANON_USER="${AKS_KUBE_CANON_USER:-aks-user}"  # defaults to aks-user if empty or unset

# ---- logging -----------------------------------------------------------------

_log() {
  local level=$1; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  printf '%s\n' "$line" >&2
  if [[ -n $LOG_FILE ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

log()   { _log INFO "$@"; }
warn()  { _log WARN "$@"; }
die()   { _log ERROR "$*"; exit 1; }

# Print current-context of a given kubeconfig file, or <none>
ctx_of() {
  KUBECONFIG="$1" kubectl config current-context 2>/dev/null || echo "<none>"
}

# ---- 0. Settings and tools ---------------------------------------------------

log "Starting AKS kubeconfig sync"
log "Tenant: ${TENANT:-<any, current az session>}, canonical user: $CANON_USER"

for bin in az kubectl kubelogin jq python3; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool not found: $bin"
done
log "Required tools found: az kubectl kubelogin jq python3"

# ---- 1. Read cluster definitions ---------------------------------------------

shopt -s nullglob
files=("$DATA_DIR"/*.toml)
(( ${#files[@]} > 0 )) || die "no *.toml files found in $DATA_DIR"
log "Reading ${#files[@]} TOML file(s) from $DATA_DIR"

for f in "${files[@]}"; do
  log "  parsing $(basename "$f")"
done

json=$(python3 - "${files[@]}" <<'PY'
import json, sys, tomllib

clusters = []
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        data = tomllib.load(f)
    clusters += data.get("kube", {}).get("aks", {}).get("clusters", [])

print(json.dumps({"clusters": clusters}))
PY
)

n_clusters=$(jq '.clusters | length' <<<"$json")
(( n_clusters > 0 )) || die "no clusters defined"
log "Found $n_clusters cluster(s)"

bad=$(jq -r '.clusters[]
  | select(.subscription == null or .name == null or .resource_group == null)
  | (.alias // .name // "?")' <<<"$json")
[[ -z $bad ]] || die "incomplete cluster data: $bad"

dup=$(jq -r '[.clusters[] | .alias // .name]
  | group_by(.) | map(select(length > 1)) | .[0][0] // empty' <<<"$json")
[[ -z $dup ]] || die "duplicate alias: $dup"

# ---- 2. Azure login and tenant -----------------------------------------------

az account show >/dev/null 2>&1 \
  || die "az is not logged in. Run: az login${TENANT:+ --tenant $TENANT}"

cur_domain=$(az account show --query tenantDefaultDomain -o tsv 2>/dev/null || true)
cur_tenant_id=$(az account show --query tenantId -o tsv 2>/dev/null || true)
cur_user=$(az account show --query user.name -o tsv 2>/dev/null || true)
log "az session: user=${cur_user:-?}, tenant=${cur_domain:-?} (${cur_tenant_id:-?})"

if [[ -n $TENANT ]]; then
  if [[ $TENANT != "$cur_domain" && $TENANT != "$cur_tenant_id" ]]; then
    die "az is logged in to tenant '$cur_domain' ($cur_tenant_id), but '$TENANT' is required"
  fi
  log "Tenant check passed"
else
  warn "AKS_TENANT is not set, using the current az session without tenant check"
fi

# ---- 3. Temporary kubeconfig -------------------------------------------------

mkdir -p "$KUBE_DIR"
tmp=$(mktemp "$KUBE_DIR/config.tmp.XXXXXX")
trap 'rm -f "$tmp" "$tmp".*' EXIT

if [[ -f $CONFIG ]]; then
  cp "$CONFIG" "$tmp"
  log "Working copy created from $CONFIG"
  log "Contexts before run: $(KUBECONFIG="$tmp" kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ')"
else
  log "No existing $CONFIG, starting with empty kubeconfig"
  : > "$tmp"
fi
export KUBECONFIG="$tmp"

orig_ctx=$(ctx_of "$CONFIG")
[[ -f $CONFIG ]] || orig_ctx="<none>"
log "Current context in $CONFIG (will be restored at end): $orig_ctx"
log "Current context in working copy: $(ctx_of "$tmp")"

# ---- 4. Fetch credentials and set namespaces ---------------------------------

mapfile -t CLUSTERS < <(jq -c '.clusters[]' <<<"$json")

i=0
for c in "${CLUSTERS[@]}"; do
  i=$((i + 1))
  ctx=$(jq -r '.alias // .name' <<<"$c")
  sub=$(jq -r '.subscription' <<<"$c")
  rg=$(jq -r '.resource_group' <<<"$c")
  name=$(jq -r '.name' <<<"$c")
  ns=$(jq -r '.namespace // empty' <<<"$c")

  log "[$i/$n_clusters] $ctx -> cluster=$name rg=$rg sub=$sub${ns:+ ns=$ns}"

  log "  fetching credentials"
  get_credentials_args=(--only-show-errors \
    --subscription "$sub" \
    --resource-group "$rg" \
    --name "$name")
  if jq -e '.alias != null' <<<"$c" >/dev/null; then
    get_credentials_args+=(--context "$ctx")
  fi
  az aks get-credentials "${get_credentials_args[@]}" \
    --overwrite-existing \
    --file "$tmp"

  if jq -e 'has("namespace")' <<<"$c" >/dev/null; then
    kubectl config set-context "$ctx" --namespace="$ns" >/dev/null
    log "  namespace set to $ns"
  fi

  kubectl config use-context "$ctx" >/dev/null
  log "  current context now: $(ctx_of "$tmp")"

  exec_cmd=$(kubectl config view --minify -o jsonpath='{.users[0].user.exec.command}')
  exec_args=$(kubectl config view --minify -o jsonpath='{.users[0].user.exec.args}')
  if [[ -n $exec_cmd ]] && ! grep -q 'azurecli' <<<"$exec_args"; then
    log "  converting kubelogin to azurecli mode"
    kubelogin convert-kubeconfig -l azurecli
  else
    log "  kubelogin conversion not needed"
  fi
done

# ---- 5. Merge managed contexts under one user --------------------------------

log "Merging users of managed contexts into '$CANON_USER'"
ctx_names=$(jq -c '[.clusters[] | .alias // .name]' <<<"$json")
kubectl config view --raw -o json > "$tmp.json"

users_before=$(jq '.users // [] | length' "$tmp.json")

jq --arg canon "$CANON_USER" --argjson managed "$ctx_names" '
  def is_managed: .name as $n | any($managed[]; . == $n);
  ([.contexts[] | select(is_managed) | .context.user] | unique) as $used
  | ((.users // []) | map(select(.name as $n | any($used[]; . == $n)))) as $mine
  | ([$mine[].user] | unique) as $tpls
  | if ($tpls | length) != 1
    then error("user configs of managed clusters differ, merge aborted")
    else . end
  | .users = ([(.users // [])[]
               | select(.name as $n | any($used[]; . == $n) | not)
               | select(.name != $canon)]
              + [{name: $canon, user: $tpls[0]}])
  | .contexts |= map(if is_managed then .context.user = $canon else . end)
' "$tmp.json" > "$tmp.merged.json" || die "failed to merge users"

users_after=$(jq '.users | length' "$tmp.merged.json")
log "Users: $users_before -> $users_after"

cp "$tmp.merged.json" "$tmp.new"

kubectl --kubeconfig="$tmp.new" config get-contexts >/dev/null \
  || die "resulting kubeconfig is invalid, original config left untouched"
log "Resulting kubeconfig is valid"

if [[ $orig_ctx != "<none>" ]] && \
   kubectl --kubeconfig="$tmp.new" config use-context "$orig_ctx" >/dev/null 2>&1; then
  log "Restored current context: $orig_ctx"
else
  warn "could not restore current context '$orig_ctx', leaving it unchanged"
fi

# ---- 6. Backup and atomic replace --------------------------------------------

if [[ -f $CONFIG ]]; then
  backup="$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONFIG" "$backup"
  log "Backup written: $backup"
fi

chmod 600 "$tmp.new"
mv "$tmp.new" "$CONFIG"
log "Config replaced: $CONFIG"

# ---- Summary -----------------------------------------------------------------

log "Current context in $CONFIG: $(ctx_of "$CONFIG")"
log "Managed contexts: $(jq -r '[.clusters[] | .alias // .name] | join(", ")' <<<"$json")"
log "Done"