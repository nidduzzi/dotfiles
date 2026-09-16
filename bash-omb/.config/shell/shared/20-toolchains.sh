# Toolchain hooks. Each block checks for the toolchain first, so this file is
# safe to load on a machine that has none of them.

# fnm: Node version manager.
FNM_PATH="$HOME/.local/share/fnm"
if [[ -d "$FNM_PATH" ]]; then
  export PATH="$FNM_PATH:$PATH"
  eval "$(fnm env)"
fi
unset FNM_PATH

# miniforge: conda and mamba.
if [[ -d "$HOME/miniforge3" ]]; then
  # >>> conda initialize >>>
  # !! Contents within this block are managed by 'conda init' !!
  __conda_setup="$("$HOME/miniforge3/bin/conda" 'shell.bash' 'hook' 2>/dev/null)"
  if [ $? -eq 0 ]; then
    eval "$__conda_setup"
  else
    if [ -f "$HOME/miniforge3/etc/profile.d/conda.sh" ]; then
      . "$HOME/miniforge3/etc/profile.d/conda.sh"
    else
      export PATH="$HOME/miniforge3/bin:$PATH"
    fi
  fi
  unset __conda_setup
  # <<< conda initialize <<<

  # >>> mamba initialize >>>
  # !! Contents within this block are managed by 'mamba shell init' !!
  export MAMBA_EXE="$HOME/miniforge3/bin/mamba"
  export MAMBA_ROOT_PREFIX="$HOME/miniforge3"
  __mamba_setup="$("$MAMBA_EXE" shell hook --shell bash --root-prefix "$MAMBA_ROOT_PREFIX" 2>/dev/null)"
  if [ $? -eq 0 ]; then
    eval "$__mamba_setup"
  else
    alias mamba="$MAMBA_EXE" # Fallback on help from mamba activate
  fi
  unset __mamba_setup
  # <<< mamba initialize <<<
fi

# Podman: prefer podman-compose over the built-in compose provider.
if command -v podman-compose &>/dev/null; then
  export PODMAN_COMPOSE_PROVIDER=podman-compose
fi

# openSUSE: work around slow multi-connection downloads.
if command -v zypper &>/dev/null; then
  export ZYPP_MEDIANETWORK=1
fi
