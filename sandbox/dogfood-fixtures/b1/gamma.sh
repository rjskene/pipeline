#!/bin/bash
# b1 dogfood fixture — gamma. Composes alpha+beta via BASH_SOURCE-relative
# source so it works regardless of CWD.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/alpha.sh"
source "$DIR/beta.sh"
b1_gamma() { echo "$(b1_alpha) $(b1_beta) b1-gamma"; }
