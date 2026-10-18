#!/bin/sh
# TPM entry point. TPM runs it inside tmux, so tmux reaches the server through TMUX.
exec tmux source-file "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/omp-tmux.conf"
