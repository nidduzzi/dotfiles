# Settings that only make sense on DEV001.
# This file is committed, so it survives a reinstall of this machine. Anything
# short-lived belongs in ~/.config/shell/local/ instead, which is never tracked.

# Hugging Face cache lives on the large secondary disk, not in $HOME.
if [[ -d /mnt/d ]]; then
  export HF_HOME=/mnt/d/.cache/huggingface/
fi

# k3s cluster, installed by k3s-ansible. `k3s completion` writes a fatal error
# to stderr when /etc/rancher is root-only, which it is on this box, so drop
# its stderr rather than greeting every new shell with it.
if command -v k3s &>/dev/null; then
  . <(k3s completion bash 2>/dev/null)
  export KUBECONFIG="$HOME/.kube/config"
fi

if command -v kubectl &>/dev/null; then
  . <(kubectl completion bash 2>/dev/null)
fi
